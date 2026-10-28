#!/bin/bash
# Every `uses:` in the workflow templates must be a remote action, owner/repo[/path], at a 40-hex commit SHA. Walks the
# parsed YAML, so an inline map, a quoted key, or a flow sequence cannot hide an unpinned action from a line-oriented
# grep; requires the remote form, so a local `./path@<40 hex>` (where the suffix is a directory name, and the code is the
# PR's) or a `docker://` image cannot pass as a pin. Exit 1 and list offenders.
cd "$(dirname "$0")/.." || exit 1
ruby -ryaml -e '
  def walk(o, &b)
    case o
    when Hash  then o.each { |k, v| b.call(v) if k.to_s == "uses"; walk(v, &b) }
    when Array then o.each { |e| walk(e, &b) }
    end
  end
  bad = []
  ARGV.each { |f| walk(YAML.load_file(f)) { |u| bad << "#{f}: uses: #{u}" unless u.to_s =~ %r{\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}\z} } }
  puts bad
  exit bad.empty?
' templates/*.yml
