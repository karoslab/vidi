/**
 * Vidi Proxy Worker — feedback relay (POST /feedback).
 *
 * A vidi-chat install POSTs user-triggered feedback (or a consented weekly
 * health summary) here; the worker forwards it to the owner's Discord via the
 * `VIDI_FEEDBACK_WEBHOOK` secret. NOTHING here originates the message — the app
 * only ever sends what the user explicitly chose to send (the zero-silent-egress
 * constraint is enforced app-side; this route is the delivery leg).
 *
 * This module is the PURE half (no env / network / KV) so the Discord message
 * shaping, the body-size cap, and the per-key send caps are unit-tested directly.
 */

/** The two kinds of message /feedback relays. Anything else is rejected 400. */
export type FeedbackKind = "feedback" | "weekly-summary";

/** Largest raw request body the route accepts (over → 413). Feedback is short
 *  free text plus an optional scrubbed diagnostics report; 32KB is generous. */
export const MAX_FEEDBACK_BODY_BYTES = 32 * 1024;

/** Per-install daily cap on ordinary feedback sends (its OWN counter, separate
 *  from the chat quota). A human sending more than this in a day is a loop. */
export const FEEDBACK_DAILY_CAP = 20;

/** Per-install WEEKLY cap on health-summary sends. The app self-limits to one
 *  per 7 days; this is the server backstop against a bug double-sending. */
export const WEEKLY_SUMMARY_WEEKLY_CAP = 2;

/** Discord's hard per-message content ceiling is 2000 chars; stay under it. */
const DISCORD_CONTENT_LIMIT = 1990;

/** Is this a kind the route relays? */
export function isFeedbackKind(value: unknown): value is FeedbackKind {
  return value === "feedback" || value === "weekly-summary";
}

/** UTC `yyyy-mm-dd` — the day bucket for the feedback counter. */
export function feedbackDateStamp(now: Date): string {
  return now.toISOString().slice(0, 10);
}

/** UTC `yyyy-Www` ISO-week-ish bucket for the weekly-summary counter. Uses the
 *  UTC-year + zero-padded week index so two sends in the same calendar week
 *  share a bucket without pulling in a date library. */
export function weekStamp(now: Date): string {
  const startOfYear = Date.UTC(now.getUTCFullYear(), 0, 1);
  const dayOfYear = Math.floor((now.getTime() - startOfYear) / 86_400_000);
  const weekIndex = Math.floor(dayOfYear / 7);
  return `${now.getUTCFullYear()}-W${String(weekIndex).padStart(2, "0")}`;
}

/**
 * Build the Discord webhook `content` string. Header names the KIND and the
 * install LABEL (so the owner knows who wrote in), then the user's text, then the
 * optional technical report in a collapsed code fence. The whole thing is
 * truncated to Discord's limit — the report is trimmed first so the human text
 * always survives.
 */
export function buildFeedbackDiscordContent(
  kind: FeedbackKind,
  label: string,
  text: string,
  report?: string | null
): string {
  const title =
    kind === "weekly-summary"
      ? `📊 Weekly health — ${label}`
      : `💬 Feedback — ${label}`;
  const head = `**${title}**\n${text.trim()}`;

  if (!report || !report.trim()) {
    return head.slice(0, DISCORD_CONTENT_LIMIT);
  }

  // Reserve room for the header + the code-fence scaffolding, then give the
  // report whatever budget remains (trim the report, never the human text).
  const fenceOpen = "\n```\n";
  const fenceClose = "\n```";
  const scaffold = head.length + fenceOpen.length + fenceClose.length;
  const reportBudget = DISCORD_CONTENT_LIMIT - scaffold;
  if (reportBudget <= 0) {
    return head.slice(0, DISCORD_CONTENT_LIMIT);
  }
  const trimmedReport =
    report.trim().length > reportBudget
      ? report.trim().slice(0, reportBudget - 1) + "…"
      : report.trim();
  return head + fenceOpen + trimmedReport + fenceClose;
}
