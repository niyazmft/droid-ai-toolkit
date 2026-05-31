## 2024-05-31 - [Optimize os.walk for node_modules]

**Learning:** `os.walk` continues to traverse subdirectories even if the main loop has a `continue` condition. This creates huge performance issues in JS/Node projects when scanning files.
**Action:** Always modify the `dirs` list in-place (e.g., `dirs[:] = [d for d in dirs if d not in ("node_modules", ".git")]`) during `os.walk` so it completely skips massive dependency trees.
