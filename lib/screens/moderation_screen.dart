import 'package:flutter/material.dart';

import '../models/community_post.dart';
import '../services/community_service.dart';
import '../theme/app_theme.dart';
import '../widgets/profile_widgets.dart';

/// Admin-only moderation queue: posts held by the coffee filter
/// (status 'pending'). Approve shows them in the feed; reject hides
/// them from everyone except their author.
class ModerationScreen extends StatelessWidget {
  const ModerationScreen({super.key, required this.service});

  final CommunityService service;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moderation'),
      ),
      body: SafeArea(
        child: StreamBuilder<List<CommunityPost>>(
          stream: service.watchPendingPosts(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final posts = snapshot.data ?? [];
            if (posts.isEmpty) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
                children: const [
                  SizedBox(height: 32),
                  EmptyState(
                    icon: Icons.shield_outlined,
                    headline: 'Nothing to review',
                    body:
                        'Posts that are not about coffee will land here for approval.',
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 96),
              itemCount: posts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final post = posts[index];
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.line),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${post.userName} · ${_timeAgo(post.createdAt)}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: p.muted),
                      ),
                      const SizedBox(height: 8),
                      Text(post.body,
                          style: Theme.of(context).textTheme.bodyMedium),
                      if (post.imageUrl != null) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            post.imageUrl!,
                            width: double.infinity,
                            fit: BoxFit.cover,
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
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            onPressed: () =>
                                _moderate(context, post.id, false),
                            icon: const Icon(Icons.close),
                            label: const Text('Reject'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: () =>
                                _moderate(context, post.id, true),
                            icon: const Icon(Icons.check),
                            label: const Text('Approve'),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _moderate(
      BuildContext context, String postId, bool approve) async {
    final ok = await service.moderatePost(postId, approve);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not update that post — check your connection.'),
        ),
      );
    }
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
