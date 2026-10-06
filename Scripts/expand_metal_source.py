#!/usr/bin/env python3
"""Flatten the shader assembly's modules for runtime Metal compilation.

Formula/ABI includes remain intact: CustomShaderCompiler supplies those sources
and uses the formula include as its insertion marker. Shader modules are header
fragments compiled once, in assembly order, by both static and runtime builds.
"""
import re
import sys
from pathlib import Path

MODULE_INCLUDE = re.compile(r'^#include "(Shaders/[^"\n]+)"\n', re.MULTILINE)


def expand_shader_source(source_path: Path) -> str:
    source = source_path.read_text(encoding="utf-8")
    return MODULE_INCLUDE.sub(
        lambda match: (source_path.parent / match[1]).read_text(encoding="utf-8"),
        source,
    )


if __name__ == "__main__":
    sys.stdout.write(expand_shader_source(Path(sys.argv[1])))
