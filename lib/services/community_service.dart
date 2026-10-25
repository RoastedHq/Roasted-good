import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../models/community_post.dart';
import '../models/post_comment.dart';
import 'coffee_filter.dart';

/// Point values for the community leaderboard.
abstract final class CommunityPoints {
  static const perPost = 10;
  static const perLike = 2;
  static const perComment = 5;
}

/// Outcome of creating a post, so the UI can explain each case.
enum PostResult {
  /// Posted and visible in the feed.
  posted,

  /// Held for admin review (not coffee-related) — visible only to
  /// its author until approved.
  heldForReview,

  /// The author already posted the daily maximum.
  dailyLimit,

  /// Network/storage failure.
  failed,
}

/// Maximum posts per user per calendar day (device-local day).
/// Admins are exempt. The Cloud Function enforces this
/// authoritatively; the client check is for instant feedback.
const maxPostsPerDay = 3;

/// Best-effort Firestore + Storage backend for the community forum.
/// Reads are a live stream; writes swallow errors so offline
/// never breaks the app.
class CommunityService {
  CommunityService(this._db, [FirebaseStorage? storage])
      : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;

  CollectionReference<Map<String, dynamic>> get _posts =>
      _db.collection('posts');

  CollectionReference<Map<String, dynamic>> _comments(String postId) =>
      _posts.doc(postId).collection('comments');

  DocumentReference<Map<String, dynamic>> _rank(String uid) =>
      _db.collection('leaderboard').doc(uid);

  /// Live feed, newest first. Only approved posts are shown, plus
  /// the viewer's own held posts (pending or rejected) so authors
  /// always see what happened to their post. Posts written before
  /// moderation existed have no status and read as approved.
  Stream<List<CommunityPost>> watchPosts({int limit = 50, String? uid}) {
    try {
      return _posts
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((snap) => [
                for (final doc in snap.docs)
                  CommunityPost.fromMap(doc.data(), doc.id),
              ]
                  .where((post) {
                    if (post.status == 'approved') return true;
                    return uid != null &&
                        post.userId == uid &&
                        (post.isPending || post.isRejected);
                  })
                  .toList());
    } catch (_) {
      return Stream.value(const []);
    }
  }

  /// True when [uid] has a document in the `admins` collection.
  /// Admins skip the coffee filter and the daily limit, and see the
  /// moderation screen.
  Future<bool> isAdmin(String uid) async {
    try {
      final doc = await _db.collection('admins').doc(uid).get();
      return doc.exists;
    } catch (_) {
      return false;
    }
  }

  /// Posts awaiting admin review, newest first. Client-side filter
  /// so no composite index is needed.
  Stream<List<CommunityPost>> watchPendingPosts({int limit = 50}) {
    try {
      return _posts
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((snap) => [
                for (final doc in snap.docs)
                  CommunityPost.fromMap(doc.data(), doc.id),
              ].where((post) => post.isPending).toList());
    } catch (_) {
      return Stream.value(const []);
    }
  }

  /// Live count of posts awaiting review, for the moderation badge.
  Stream<int> watchPendingCount() =>
      watchPendingPosts().map((posts) => posts.length);

  /// Approve or reject a held post. Requires the Firestore rules
  /// admin override (see the rules snippet shipped with this feature).
  Future<bool> moderatePost(String postId, bool approve) async {
    try {
      await _posts.doc(postId).update({
        'status': approve ? 'approved' : 'rejected',
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True when the user already posted [maxPostsPerDay] times today
  /// (device-local calendar day). All of today's posts count,
  /// including held and rejected ones, so the moderation queue can't
  /// be spammed. On query failure (e.g. the composite index isn't
  /// deployed yet) returns false — the Cloud Function enforces the
  /// limit authoritatively, so posting must never break here.
  Future<bool> _atDailyLimit(String userId) async {
    try {
      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final snap = await _posts
          .where('userId', isEqualTo: userId)
          .where('createdAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(todayStart))
          .orderBy('createdAt', descending: true)
          .limit(maxPostsPerDay)
          .get();
      return snap.docs.length >= maxPostsPerDay;
    } catch (_) {
      return false;
    }
  }

  Future<PostResult> createPost({
    required String userId,
    required String userName,
    required String kind,
    required String body,
    XFile? image,
  }) async {
    try {
      final admin = await isAdmin(userId);
      if (!admin && await _atDailyLimit(userId)) {
        return PostResult.dailyLimit;
      }
      final doc = _posts.doc();
      String? imageUrl;
      if (image != null) {
        imageUrl = await _uploadImage(doc.id, image);
        if (imageUrl == null) return PostResult.failed;
      }
      final status = admin
          ? 'approved'
          : (isCoffeeRelated(body) ? 'approved' : 'pending');
      await doc.set(CommunityPost(
        id: '',
        userId: userId,
        userName: userName,
        kind: kind,
        body: body.trim(),
        imageUrl: imageUrl,
        createdAt: DateTime.now(),
        status: status,
      ).toMap());
      await _awardPoints(
        uid: userId,
        userName: userName,
        points: CommunityPoints.perPost,
        postDelta: 1,
      );
      return status == 'pending' ? PostResult.heldForReview : PostResult.posted;
    } catch (_) {
      return PostResult.failed;
    }
  }

  /// Uploads a post photo to `posts/<postId>.jpg`.
  /// Returns the download URL, or null when the upload fails.
  Future<String?> _uploadImage(String postId, XFile image) async {
    try {
      final bytes = await image.readAsBytes();
      final ref = _storage.ref('posts/$postId.jpg');
      await ref.putData(
        bytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      return await ref.getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  /// Toggles the user's like. Returns false when offline.
  /// Liking earns the liker [CommunityPoints.perLike] points;
  /// unliking takes them back.
  Future<bool> toggleLike(CommunityPost post, String uid,
      {String userName = 'Coffee lover'}) async {
    try {
      final ref = _posts.doc(post.id);
      final liked = post.likedBy.contains(uid);
      await ref.update({
        'likedBy': liked
            ? FieldValue.arrayRemove([uid])
            : FieldValue.arrayUnion([uid]),
        'likeCount': FieldValue.increment(liked ? -1 : 1),
      });
      await _awardPoints(
        uid: uid,
        userName: userName,
        points: liked
            ? -CommunityPoints.perLike
            : CommunityPoints.perLike,
        likeDelta: liked ? -1 : 1,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Live comments for a post, newest first.
  Stream<List<PostComment>> watchComments(String postId,
      {int limit = 50}) {
    try {
      return _comments(postId)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((snap) => [
                for (final doc in snap.docs)
                  PostComment.fromMap(doc.data(), doc.id),
              ]);
    } catch (_) {
      return Stream.value(const []);
    }
  }

  /// Adds a comment and awards the commenter
  /// [CommunityPoints.perComment] points. When [parentCommentId] is
  /// set, the comment is a reply to that top-level comment.
  Future<bool> addComment({
    required String postId,
    required String userId,
    required String userName,
    required String body,
    String? parentCommentId,
  }) async {
    try {
      await _comments(postId).add(PostComment(
        id: '',
        userId: userId,
        userName: userName,
        body: body.trim(),
        createdAt: DateTime.now(),
        parentCommentId: parentCommentId,
      ).toMap());
      await _posts.doc(postId).update({
        'commentCount': FieldValue.increment(1),
      });
      await _awardPoints(
        uid: userId,
        userName: userName,
        points: CommunityPoints.perComment,
        commentDelta: 1,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Live leaderboard, highest points first.
  Stream<List<LeaderboardEntry>> watchLeaderboard(
      {int limit = 50}) {
    try {
      return _db
          .collection('leaderboard')
          .orderBy('points', descending: true)
          .limit(limit)
          .snapshots()
          .map((snap) => [
                for (final doc in snap.docs)
                  LeaderboardEntry.fromMap(doc.data(), doc.id),
              ]);
    } catch (_) {
      return Stream.value(const []);
    }
  }

  /// Adds points to the user's own leaderboard entry.
  /// Best-effort: failures never surface to the UI.
  Future<void> _awardPoints({
    required String uid,
    required String userName,
    required int points,
    int postDelta = 0,
    int likeDelta = 0,
    int commentDelta = 0,
  }) async {
    try {
      await _rank(uid).set(
        {
          'userName': userName,
          'points': FieldValue.increment(points),
          'postCount': FieldValue.increment(postDelta),
          'likeCount': FieldValue.increment(likeDelta),
          'commentCount': FieldValue.increment(commentDelta),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {}
  }
}
