// The pure part of the read guard: which Read calls are refused, and with what words.
//
// Measured on the owner's box, 2026-10-23, 14:12–15:12 UTC, seven busy agents: 3.0M characters of tool
// output reached the models in the hour, and 1.5M of it was twenty whole-file Reads. Eleven were PNG
// screenshots at 90k–180k characters each, three of them read twice by the same agent from two
// checkouts of one commit; one was a 400k-character generated script read whole and then read again as
// the slice that was wanted. The engine already answers a repeat Read of an UNCHANGED TEXT file with
// `file_unchanged` and auto-paginates a text file over its token cap, so this guard covers only what
// the engine leaves open: images, which are never deduplicated, and a whole-file read that the cap
// does not catch.

// An image, by the extension the Read tool renders as one.
export const IMAGE = /\.(png|jpe?g|gif|webp)$/i
// The Read tool handles these on its own terms (pages, cells); the size rule does not apply.
export const PAGED = /\.(pdf|ipynb)$/i
// A text file this large read whole is about 1,500 lines of code or more; pass offset and limit.
export const LARGE_BYTES = 64 * 1024

export type ReadArgs = { file_path: string; offset?: number; limit?: number; allow_large?: boolean }

export function basename(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1)
}

// The identity of an image for the repeat rule: its name and byte size. Two checkouts of one commit
// hold the same file under different paths and mtimes (git stamps a checkout's mtime), and that pair
// is exactly the repeat the rule exists to stop; a re-saved screenshot changes size and reads anew.
export function imageKey(path: string, size: number): string {
  return `${basename(path)}:${size}`
}

export type Verdict = { deny: string } | { allow: true; key?: string }

// The verdict on one Read, given the file's size: `key` is set when the call is an image read that
// should be remembered as seen. `seen` holds the keys this loop has read since its last compaction.
export function judge(args: ReadArgs, size: number, seen: ReadonlySet<string>): Verdict {
  const path = args.file_path
  if (IMAGE.test(path)) {
    const key = imageKey(path, size)
    if (seen.has(key)) {
      return { deny: `read-guard: ${basename(path)} (${size} bytes) is already in this context, read earlier this session; a repeat costs the same again and shows nothing new. Reason from the copy you have. It reads again after a compaction, or once the file changes.` }
    }
    return { allow: true, key }
  }
  if (PAGED.test(path)) return { allow: true }
  const bounded = args.offset !== undefined || args.limit !== undefined || args.allow_large === true
  if (!bounded && size > LARGE_BYTES) {
    const kb = Math.round(size / 1024)
    return { deny: `read-guard: ${basename(path)} is ${kb} KiB, and a Read with no offset and limit would put all of it in the context. Pass offset and limit for the part you need, or search it (grep -n) first; allow_large: true reads it whole when you truly need every line.` }
  }
  return { allow: true }
}
