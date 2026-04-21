require "minitest/autorun"
require "../src/omq"

# Require every *_test.cr under this directory.
{% for path in `find test -name '*_test.cr' | sort`.stringify.split('\n').reject(&.empty?) %}
  require {{ "../" + path.id.stringify }}
{% end %}
