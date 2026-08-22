#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).resolve().parent / "v06_patch.py"
text = path.read_text()
old = '''replace_once(\n    "src/mongo/runtime_client.zig",\n    '};\\n',\n    '};\\n\\nfn isRetryableReadFailure(err: anyerror) bool {\\n    return err == error.RetryableRead or error_response.isRetryableTransportError(err);\\n}\\n',\n)'''
new = '''append_once(\n    "src/mongo/runtime_client.zig",\n    '};\\n',\n    '\\nfn isRetryableReadFailure(err: anyerror) bool {\\n    return err == error.RetryableRead or error_response.isRetryableTransportError(err);\\n}\\n',\n)'''
if text.count(old) != 1:
    raise SystemExit(f"expected one bad facade anchor, found {text.count(old)}")
path.write_text(text.replace(old, new, 1))
print("fixed v0.6 facade append anchor")
