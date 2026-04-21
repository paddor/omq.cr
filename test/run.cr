require "minitest/autorun"
require "../src/omq"

# Require every *_test.cr under test/omq. test/system/ holds opt-in
# cross-language interop tests (Ruby subprocesses) and has its own runner.
{% for path in `find test/omq -name '*_test.cr' | sort`.stringify.split('\n').reject(&.empty?) %}
  require {{ "../" + path.id.stringify }}
{% end %}
