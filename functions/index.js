/**
 * Roasted push notifications (Firebase Cloud Functions, 2nd gen).
 *
 * Triggers:
 * - onCommentCreated: someone comments on your post  -> notify post author
 * - onCommentReplyCreated: someone replies to your comment -> notify parent comment author
 * - onPostLiked:      someone likes your post        -> notify post author
 * - onPostCreated:    new post                       -> enforce the 3/day
 *   limit, re-check the coffee filter, notify admins of held posts
 *
 * Device tokens live at users/{uid}/private/fcm (written by the app's
 * NotificationService). Self-actions never notify.
 *
 * Deploy: firebase deploy --only functions
 * (requires the Blaze pay-as-you-go plan; free tier is generous)
 */
const {onDocumentCreated, onDocumentUpdated} = require('firebase-functions/v2/firestore');
const {initializeApp} = require('firebase-admin/app');
const {getFirestore, FieldValue} = require('firebase-admin/firestore');
const {getMessaging} = require('firebase-admin/messaging');

initializeApp();
const db = getFirestore();

async function tokenFor(uid) {
  const snap = await db.collection('users').doc(uid)
      .collection('private').doc('fcm').get();
  return snap.exists ? snap.data().token : null;
}

async function notifyUser(uid, title, body, data = {}) {
  const token = await tokenFor(uid);
  if (!token) return;
  try {
    await getMessaging().send({token,
      notification: {title, body},
      data: {...data, click_action: 'FLUTTER_NOTIFICATION_CLICK'},
      apns: {payload: {aps: {sound: 'default'}}},
    });
  } catch (e) {
    // Stale token — drop it so future sends don't keep failing.
    if (e.code === 'messaging/registration-token-not-registered') {
      await db.collection('users').doc(uid)
          .collection('private').doc('fcm').delete();
    }
  }
}

exports.onCommentCreated = onDocumentCreated(
    'posts/{postId}/comments/{commentId}',
    async (event) => {
      const comment = event.data.data();
      const {postId} = event.params;
      const postSnap = await db.collection('posts').doc(postId).get();
      if (!postSnap.exists) return;
      const post = postSnap.data();
      // Don't notify when the author comments on their own post.
      if (!post.userId || post.userId === comment.userId) return;
      await notifyUser(
          post.userId,
          'New comment on your post',
          `${comment.userName || 'Someone'}: ${comment.body || ''}`.slice(0, 120),
          {type: 'comment', postId},
      );
    });

// A reply is also a comment, so onCommentCreated already notifies the
// post author. This trigger covers the other person in the thread: the
// author of the comment being replied to. Skipped when that person is
// the post author (already notified) or the replier themselves.
exports.onCommentReplyCreated = onDocumentCreated(
    'posts/{postId}/comments/{commentId}',
    async (event) => {
      const comment = event.data.data();
      const {postId} = event.params;
      const parentId = comment.parentCommentId;
      if (!parentId) return; // top-level comment, not a reply
      const parentSnap = await db.collection('posts').doc(postId)
          .collection('comments').doc(parentId).get();
      if (!parentSnap.exists) return;
      const parent = parentSnap.data();
      if (!parent.userId || parent.userId === comment.userId) return;
      const postSnap = await db.collection('posts').doc(postId).get();
      if (postSnap.exists && postSnap.data().userId === parent.userId) return;
      await notifyUser(
          parent.userId,
          'New reply to your comment',
          `${comment.userName || 'Someone'}: ${comment.body || ''}`.slice(0, 120),
          {type: 'reply', postId, commentId: parentId},
      );
    });

exports.onPostLiked = onDocumentUpdated(
    'posts/{postId}',
    async (event) => {
      const before = event.data.before.data().likedBy || [];
      const after = event.data.after.data().likedBy || [];
      if (after.length <= before.length) return; // unlike or no change
      const newLiker = after.find((uid) => !before.includes(uid));
      const post = event.data.after.data();
      if (!newLiker || !post.userId || newLiker === post.userId) return;
      await notifyUser(
          post.userId,
          'Someone liked your post',
          'Your post got some love in the Community.',
          {type: 'like', postId: event.params.postId},
      );
    });

// ------------------------------------------------------------------
// Community moderation: coffee filter + 3 posts/day limit.
// Mirrors lib/services/coffee_filter.dart — keep the two lists in sync.
// ------------------------------------------------------------------

// Single coffee words, lowercase, accents stripped.
const COFFEE_WORDS = new Set([
  'coffee', 'cafe', 'espresso', 'latte', 'cappuccino', 'mocha',
  'americano', 'macchiato', 'cortado', 'bean', 'beans', 'roast',
  'roasting', 'roaster', 'torrefaction', 'brew', 'brewing', 'brasseur',
  'barista', 'grinder', 'moulin', 'crema', 'arabica', 'robusta',
  'decaf', 'blend', 'origin', 'origine', 'caffeine', 'cafeine',
  'percolator', 'keurig', 'nespresso', 'drip', 'filter', 'filtre',
  'iced', 'affogato', 'ristretto', 'lungo', 'doppio', 'turkish',
  'moka', 'carafe', 'cup', 'tasse', 'mug', 'milk', 'lait', 'sip',
  'tasting', 'degustation', 'aroma', 'arome', 'flavour', 'flavor',
  'saveur', 'chocolate', 'chocolat', 'caramel', 'fruity', 'fruite',
  'nutty', 'floral', 'extraction', 'grind', 'mouture', 'dose',
  'tamper', 'portafilter', 'kettle', 'bouilloire', 'scale', 'balance',
  'timer', 'recipe', 'recette', 'method', 'methode', 'aeropress',
  'chemex', 'v60', 'pourover', 'coldbrew', 'siphon', 'kalita',
  'melitta',
]);

// Multi-word coffee phrases, lowercase, accents stripped.
const COFFEE_PHRASES = [
  'flat white', 'cold brew', 'french press', 'pour over',
  'coffee shop', 'coffee bean', 'coffee beans', 'coffee lover',
  'coffee lovers', 'oat milk', 'lait d avoine', 'coffee break',
  'pause cafe', 'morning coffee', 'coffee time', 'coffee run',
  'coffee date', 'coffee machine', 'machine a cafe', 'coffee maker',
  'coffee cup', 'tasse de cafe', 'cup of coffee', 'latte art',
  'coffee grounds', 'marc de cafe', 'coffee filter', 'filtre a cafe',
  'coffee grinder', 'moulin a cafe', 'coffee roaster', 'torrefacteur',
  'coffee bar', 'coffee house', 'coffee recipe', 'recette de cafe',
  'coffee tasting', 'degustation de cafe',
];

// Generous on purpose: a false positive just lets a post through,
// a false negative holds a good post for review. Words match
// whole-word only ('bean' must not match 'beanie').
function isCoffeeRelated(body) {
  const text = (body || '').toLowerCase()
      .normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  for (const phrase of COFFEE_PHRASES) {
    if (text.includes(phrase)) return true;
  }
  const words = text.split(/[^a-z0-9]+/);
  for (const word of words) {
    if (word && COFFEE_WORDS.has(word)) return true;
  }
  return false;
}

// Offset of America/Toronto from UTC at a given instant, in ms.
function torontoOffsetAt(date) {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Toronto', hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
  const parts = {};
  for (const p of dtf.formatToParts(date)) parts[p.type] = p.value;
  const hour = parts.hour === '24' ? '00' : parts.hour;
  const asUTC = Date.UTC(+parts.year, +parts.month - 1, +parts.day,
      +hour, +parts.minute, +parts.second);
  return asUTC - Math.floor(date.getTime() / 1000) * 1000;
}

// Start of today in America/Toronto, as a JS Date (UTC instant).
function torontoMidnightToday() {
  const dateStr = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Toronto',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date());
  const midnightUTC = new Date(dateStr + 'T00:00:00.000Z');
  // Correct the UTC guess by the Toronto offset at that instant.
  // Two iterations converge (Toronto DST shifts happen at 2am, never
  // at midnight).
  let guess = midnightUTC;
  for (let i = 0; i < 2; i++) {
    guess = new Date(midnightUTC.getTime() - torontoOffsetAt(guess));
  }
  return guess;
}

const MAX_POSTS_PER_DAY = 3;

exports.onPostCreated = onDocumentCreated(
    'posts/{postId}',
    async (event) => {
      const post = event.data.data();
      const postId = event.params.postId;
      if (!post.userId) return;
      const postRef = db.collection('posts').doc(postId);

      // Admins skip moderation entirely.
      const adminSnap = await db.collection('admins').doc(post.userId).get();
      if (adminSnap.exists) {
        if (post.status !== 'approved') {
          await postRef.update({status: 'approved'});
        }
        return;
      }

      // Daily limit (Toronto calendar day): count the author's posts
      // from today, including this one. Over the limit, the post is
      // rejected — the author sees it with a "not approved" chip,
      // everyone else never sees it.
      const todayStart = torontoMidnightToday();
      let todayCount;
      try {
        const todays = await db.collection('posts')
            .where('userId', '==', post.userId)
            .where('createdAt', '>=', todayStart)
            .get();
        todayCount = todays.size;
      } catch (e) {
        // Composite index not deployed yet: count client-side.
        const all = await db.collection('posts')
            .where('userId', '==', post.userId)
            .limit(100)
            .get();
        todayCount = all.docs.filter((d) => {
          const ts = d.data().createdAt;
          const ms = ts && typeof ts.toMillis === 'function' ?
            ts.toMillis() : 0;
          return ms >= todayStart.getTime();
        }).length;
      }
      if (todayCount > MAX_POSTS_PER_DAY) {
        await postRef.update({status: 'rejected'});
        return;
      }

      // Coffee filter (authoritative re-check): the client sets the
      // status first for instant feedback; the Function corrects
      // bypasses and notifies admins for held posts.
      if (isCoffeeRelated(post.body || '')) {
        if (post.status !== 'approved') {
          await postRef.update({status: 'approved'});
        }
        return;
      }
      // Not coffee-related: hold for review and notify every admin.
      if (post.status !== 'pending') {
        await postRef.update({status: 'pending'});
      }
      const admins = await db.collection('admins').get();
      for (const admin of admins.docs) {
        if (admin.id === post.userId) continue;
        await notifyUser(
            admin.id,
            'Post awaiting review',
            `${post.userName || 'Someone'} posted something that ` +
              'doesn\'t look coffee-related.',
            {type: 'moderation', postId},
        );
      }
    });
