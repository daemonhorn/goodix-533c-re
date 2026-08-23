"""Inserts 'from __future__ import annotations' right after a module's
opening docstring, for files where line-1 insertion would violate
Python's future-statement placement rule. Used by
usbmon-capture-in-vm.sh to make driver_53xc.py's PEP 604/585 type hints
(list[int], float | None, ...) parse on this VM's Python 3.8.
"""
import sys

path = sys.argv[1]
src = open(path).read()
end = src.index('"""', 3) + 3
open(path, "w").write(src[:end] + "\n\nfrom __future__ import annotations\n" + src[end:])
