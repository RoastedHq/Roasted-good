import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/community_post.dart';
import '../models/post_comment.dart';
import '../services/community_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/profile_widgets.dart';
import 'leaderboard_screen.dart';
import 'moderation_screen.dart';

/// Community: a minimalist forum for brew notes, tastings,
/// questions and coffee chat. Backed by the shared `posts`
/// Firestore collection; works offline via best-effort sync.
class CommunityScreen extends StatelessWidget {
  const CommunityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final state = AppState.of(context);
    // Firebase isn't initialized in widget tests / offline previews —
    // fall back to a quiet empty state instead of crashing.
    CommunityService? service;
    try {
      service = CommunityService(FirebaseFirestore.instance);
    } catch (_) {
      service = null;
    }
    final svc = service;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Community'),
        actions: [
          if (svc != null && state.uid != null)
            _ModerationAction(service: svc, uid: state.uid),
          if (svc != null)
            IconButton(
              tooltip: 'Leaderboard',
              icon: const Icon(Icons.emoji_events_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LeaderboardScreen(),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: svc == null || state.uid == null
          ? null
          : FloatingActionButton(
              tooltip: 'New post',
              backgroundColor: p.ink,
              foregroundColor: p.onIdentityCard,
              onPressed: () => _showComposeSheet(context, svc, state),
              child: const Icon(Icons.add),
            ),
      body: SafeArea(
        child: svc == null
            ? ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
                children: const [
                  SizedBox(height: 32),
                  EmptyState(
                    icon: Icons.forum_outlined,
                    headline: 'Community is offline',
                    body:
                        'Check your connection — the conversation will be here when you are back.',
                  ),
                ],
              )
            : StreamBuilder<List<CommunityPost>>(
                stream: svc.watchPosts(uid: state.uid),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final posts = snapshot.data ?? [];
            if (posts.isEmpty) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
                children: [
                  const SizedBox(height: 32),
                  EmptyState(
                    icon: Icons.forum_outlined,
                    headline: 'No posts yet',
                    body:
                        'Share a brewing note, a tasting, or ask the community — be the first to post.',
                    ctaLabel: state.uid == null
                        ? 'Sign in to post'
                        : 'Write a post',
                    onCta: () => state.uid == null
                        ? null
                        : _showComposeSheet(context, svc, state),
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 96),
              itemCount: posts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) => _PostCard(
                post: posts[index],
                service: svc,
                uid: state.uid,
                userName: state.userName.isEmpty
                    ? 'Coffee lover'
                    : state.userName,
              ),
            );
          },
        ),
      ),
    );
  }

  void _showComposeSheet(
    BuildContext context,
    CommunityService service,
    AppState state,
  ) {
    final uid = state.uid;
    if (uid == null) return;
    final name =
        state.userName.isEmpty ? 'Coffee lover' : state.userName;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 12,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 32,
        ),
        child: _ComposeForm(
          onPost: (kind, body, image) async {
            final result = await service.createPost(
              userId: uid,
              userName: name,
              kind: kind,
              body: body,
              image: image,
            );
            if (sheetContext.mounted) {
              Navigator.of(sheetContext).pop();
              if (context.mounted) {
                switch (result) {
                  case PostResult.posted:
                    break;
                  case PostResult.heldForReview:
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Your post is awaiting review — it will appear once approved.'),
                      ),
                    );
                  case PostResult.dailyLimit:
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'You have reached 3 posts for today — come back tomorrow!'),
                      ),
                    );
                  case PostResult.failed:
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                            'Could not post right now — check your connection.'),
                      ),
                    );
                }
              }
            }
          },
        ),
      ),
    );
  }
}

/// AppBar moderation entry: visible only to admins, with a badge
/// showing how many posts await review.
class _ModerationAction extends StatelessWidget {
  const _ModerationAction({required this.service, required this.uid});

  final CommunityService service;
  final String? uid;

  @override
  Widget build(BuildContext context) {
    final id = uid;
    if (id == null) return const SizedBox.shrink();
    return FutureBuilder<bool>(
      future: service.isAdmin(id),
      builder: (context, adminSnap) {
        if (adminSnap.data != true) return const SizedBox.shrink();
        return StreamBuilder<int>(
          stream: service.watchPendingCount(),
          builder: (context, countSnap) {
            final count = countSnap.data ?? 0;
            return Badge(
              isLabelVisible: count > 0,
              label: Text('$count'),
              child: IconButton(
                tooltip: 'Moderation',
                icon: const Icon(Icons.shield_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ModerationScreen(service: service),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.post,
    required this.service,
    required this.uid,
    required this.userName,
  });

  final CommunityPost post;
  final CommunityService service;
  final String? uid;
  final String userName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final liked = post.likedByUser(uid);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: p.surfaceVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  communityKindLabels[post.kind] ?? 'Chat',
                  style: theme.textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${post.userName} · ${_timeAgo(post.createdAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: p.muted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Authors see what happened to their own held posts.
              if ((post.isPending || post.isRejected) &&
                  post.userId == uid) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: p.surfaceVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    post.isPending ? 'Pending approval' : 'Not approved',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(post.body, style: theme.textTheme.bodyMedium),
          if (post.imageUrl != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                post.imageUrl!,
                width: double.infinity,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, progress) =>
                    progress == null
                        ? child
                        : const SizedBox(
                            height: 180,
                            child: Center(
                                child:
                                    CircularProgressIndicator()),
                          ),
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox(
                  height: 120,
                  child: Center(
                    child: Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              InkWell(
                onTap: () => showCommentsSheet(context, post, service),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 18,
                        color: p.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${post.commentCount}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: p.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              InkWell(
                onTap: uid == null
                    ? null
                    : () => service.toggleLike(
                          post,
                          uid!,
                          userName: userName,
                        ),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        liked
                            ? Icons.favorite
                            : Icons.favorite_border,
                        size: 18,
                        color: liked ? Colors.redAccent : p.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${post.likeCount}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: p.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ComposeForm extends StatefulWidget {
  const _ComposeForm({required this.onPost});

  final Future<void> Function(String kind, String body, XFile? image)
      onPost;

  @override
  State<_ComposeForm> createState() => _ComposeFormState();
}

class _ComposeFormState extends State<_ComposeForm> {
  String _kind = 'brewing';
  final _controller = TextEditingController();
  final _picker = ImagePicker();
  XFile? _image;
  bool _posting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (file != null && mounted) setState(() => _image = file);
    } catch (_) {
      // Picker cancelled or unavailable — stay on the form.
    }
  }

  void _chooseImageSource() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: p.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('New post', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in communityKindLabels.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: _kind == entry.key,
                showCheckmark: false,
                onSelected: (_) =>
                    setState(() => _kind = entry.key),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          maxLines: 5,
          minLines: 3,
          maxLength: 500,
          decoration: const InputDecoration(
            hintText:
                'What are you brewing? Share a tasting, ask a question…',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        // Photo attachment.
        if (_image != null)
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FutureBuilder<Uint8List>(
                  future: _image!.readAsBytes(),
                  builder: (context, snap) => snap.hasData
                      ? Image.memory(
                          snap.data!,
                          height: 160,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        )
                      : const SizedBox(
                          height: 160,
                          child: Center(
                              child: CircularProgressIndicator()),
                        ),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 18,
                    ),
                    onPressed: () =>
                        setState(() => _image = null),
                  ),
                ),
              ),
            ],
          )
        else
          OutlinedButton.icon(
            icon: const Icon(Icons.add_a_photo_outlined, size: 20),
            label: const Text('Add a photo'),
            onPressed: _chooseImageSource,
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _controller.text.trim().isEmpty || _posting
                ? null
                : () async {
                    setState(() => _posting = true);
                    await widget.onPost(
                      _kind,
                      _controller.text.trim(),
                      _image,
                    );
                  },
            child: _posting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Post'),
          ),
        ),
      ],
    );
  }
}

String _timeAgo(DateTime date) {
  final diff = DateTime.now().difference(date);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${date.month}/${date.day}/${date.year}';
}

/// Opens the comments thread for [post] as a bottom sheet.
void showCommentsSheet(
  BuildContext context,
  CommunityPost post,
  CommunityService service,
) {
  final state = AppState.of(context);
  final uid = state.uid;
  final userName =
      state.userName.isEmpty ? 'Coffee lover' : state.userName;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.palette.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _CommentsSheet(
        post: post,
        service: service,
        uid: uid,
        userName: userName,
      ),
    ),
  );
}

class _CommentsSheet extends StatefulWidget {
  const _CommentsSheet({
    required this.post,
    required this.service,
    required this.uid,
    required this.userName,
  });

  final CommunityPost post;
  final CommunityService service;
  final String? uid;
  final String userName;

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _controller = TextEditingController();
  bool _sending = false;
  PostComment? _replyTo;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: p.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Text('Comments', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<List<PostComment>>(
                stream:
                    widget.service.watchComments(widget.post.id),
                builder: (context, snapshot) {
                  final comments = snapshot.data ?? [];
                  if (comments.isEmpty) {
                    return Center(
                      child: Text(
                        'No comments yet — start the conversation.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: p.muted,
                        ),
                      ),
                    );
                  }
                  // Threaded view: top-level comments newest first,
                  // replies oldest-first under their parent.
                  final topLevel = comments
                      .where((c) => c.parentCommentId == null)
                      .toList();
                  final repliesByParent =
                      <String, List<PostComment>>{};
                  for (final c in comments) {
                    final parentId = c.parentCommentId;
                    if (parentId != null) {
                      repliesByParent
                          .putIfAbsent(parentId, () => [])
                          .add(c);
                    }
                  }
                  for (final replies in repliesByParent.values) {
                    replies.sort((a, b) =>
                        a.createdAt.compareTo(b.createdAt));
                  }
                  return ListView.separated(
                    padding:
                        const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    itemCount: topLevel.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: 16),
                    itemBuilder: (context, index) {
                      final c = topLevel[index];
                      final replies =
                          repliesByParent[c.id] ?? const [];
                      return Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          _commentTile(context, c),
                          for (final r in replies)
                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 20, top: 10),
                              child: _commentTile(context, r),
                            ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            if (widget.uid != null)
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_replyTo != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Replying to ${_replyTo!.userName}',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: p.muted),
                              ),
                            ),
                            InkWell(
                              onTap: () =>
                                  setState(() => _replyTo = null),
                              child: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            maxLength: 300,
                            decoration: InputDecoration(
                              hintText: _replyTo == null
                                  ? 'Write a comment…'
                                  : 'Write a reply…',
                              border: const OutlineInputBorder(),
                              counterText: '',
                            ),
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send, size: 20),
                      onPressed:
                          _controller.text.trim().isEmpty ||
                                  _sending
                              ? null
                              : _send,
                    ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One comment row: name + time, an "Author" badge when the
  /// commenter wrote the post, the body, and a Reply button.
  Widget _commentTile(BuildContext context, PostComment c) {
    final theme = Theme.of(context);
    final p = context.palette;
    final isAuthor = c.userId == widget.post.userId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${c.userName} · ${_timeAgo(c.createdAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: p.muted,
                ),
              ),
            ),
            if (isAuthor)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Author',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: p.onAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(c.body, style: theme.textTheme.bodyMedium),
        if (widget.uid != null)
          InkWell(
            onTap: () => setState(() => _replyTo = c),
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Reply',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: p.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending || widget.uid == null) return;
    setState(() => _sending = true);
    final replyTo = _replyTo;
    final ok = await widget.service.addComment(
      postId: widget.post.id,
      userId: widget.uid!,
      userName: widget.userName,
      body: text,
      parentCommentId:
          replyTo == null ? null : (replyTo.parentCommentId ?? replyTo.id),
    );
    if (mounted) {
      setState(() => _sending = false);
      if (ok) {
        _controller.clear();
        setState(() => _replyTo = null);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Could not post — check your connection.'),
          ),
        );
      }
    }
  }
}
