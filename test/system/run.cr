require "./system_test_helper"

# Opt-in cross-language interop runner. Not picked up by test/run.cr —
# invoke explicitly:
#
#     crystal run test/system/run.cr
#
# Requires a Ruby interpreter on PATH (or pointed to by OMQ_RUBY_BIN)
# with the `omq` gem installed. Tests self-skip if not available.

{% for path in `find test/system -name 'interop_*_test.cr' | sort`.stringify.split('\n').reject(&.empty?) %}
  require {{ "../../" + path.id.stringify }}
{% end %}
