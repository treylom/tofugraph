#!/usr/bin/env python3
"""tofugraph viz — assemble a single self-contained HTML 3D graph viewer.

Embeds the vendored 3d-force-graph.min.js, three.module.min.js + three.core.min.js,
and an exported graph3d-data.json into one .html file that opens directly from
file:// with NO server and NO network access (offline-safe for students).

MEASURED (not assumed) via headless Chrome against file://, see plugin README:
  - 3d-force-graph.min.js is a classic UMD bundle → safe to inline verbatim as a
    plain <script> (it reads window.THREE lazily at call time only, and also
    vendors its own internal three.js copy as a fallback).
  - three.module.min.js is an ES module that internally does, TWICE:
        import {...} from "./three.core.min.js"
    A relative specifier can't be resolved against a blob: URL's base (no
    hierarchical path) — naively Blob-importing three.module.min.js alone fails
    with "Invalid relative url or base scheme isn't hierarchical". A dynamically
    inserted <script type="importmap"> remap was tried first and did NOT fix it
    empirically. Fix that DID work: Blob-URL three.core.min.js first, then
    text-patch (replaceAll — NOT a plain .replace(), which only hits the first
    of the two occurrences and leaves the second broken) the literal
    "./three.core.min.js" specifier inside the decoded three.module.min.js
    source to point at that Blob URL, then Blob-URL the patched module text and
    dynamic-import() it.
  - fetch("data.json") is blocked under file:// (local-file CORS) regardless —
    replaced with reading an embedded `window.__GRAPH_DATA__` global instead.
"""
import argparse, base64, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR_DIR = os.path.join(HERE, "vendor")
TEMPLATE = os.path.join(HERE, "viewer_template.html")


def resolve_data(cli_val):
    if cli_val:
        return cli_val
    if os.environ.get("TOFUGRAPH_OUT"):
        return os.environ["TOFUGRAPH_OUT"]
    return os.path.join(os.getcwd(), "graph3d-data.json")


def resolve_out(cli_val):
    if cli_val:
        return cli_val
    if os.environ.get("TOFUGRAPH_VIZ_OUT"):
        return os.environ["TOFUGRAPH_VIZ_OUT"]
    return os.path.join(os.getcwd(), "graph3d.html")


def build(data_path, out_path, vendor_dir=VENDOR_DIR, template_path=TEMPLATE):
    if not os.path.isfile(data_path):
        raise FileNotFoundError(
            f"graph data json not found: {data_path}\n"
            f"  fix: run export_data.py first (produces graph3d-data.json), or pass --data <path>"
        )
    with open(os.path.join(vendor_dir, "3d-force-graph.min.js")) as f:
        fg3d_js = f.read()
    with open(os.path.join(vendor_dir, "three.module.min.js"), "rb") as f:
        three_module_b64 = base64.b64encode(f.read()).decode("ascii")
    with open(os.path.join(vendor_dir, "three.core.min.js"), "rb") as f:
        three_core_b64 = base64.b64encode(f.read()).decode("ascii")
    with open(data_path) as f:
        parsed = json.load(f)

    data_json_min = json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))
    # guard against a note title/path containing a literal "</script" sequence
    # breaking out of the embedding <script> tag.
    data_json_safe = data_json_min.replace("</script", "<\\/script").replace("<script", "<\\script")

    three_loader = f"""<script>
(function() {{
  function b64ToBytes(b64) {{
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }}
  var coreBytes = b64ToBytes("{three_core_b64}");
  var coreBlobUrl = URL.createObjectURL(new Blob([coreBytes], {{ type: "text/javascript" }}));

  var moduleBytes = b64ToBytes("{three_module_b64}");
  var moduleText = new TextDecoder("utf-8").decode(moduleBytes);
  var patched = moduleText.replaceAll('"./three.core.min.js"', JSON.stringify(coreBlobUrl));
  if (patched === moduleText) {{
    console.error("[tofugraph] three.core.min.js specifier not found — vendored three.js changed shape?");
  }}
  window.__THREE_MODULE_URL__ = URL.createObjectURL(new Blob([patched], {{ type: "text/javascript" }}));
}})();
</script>"""

    data_block = f"<script>\nwindow.__GRAPH_DATA__ = {data_json_safe};\n</script>"

    with open(template_path) as f:
        html = f.read()

    assert "<!--TOFUGRAPH:FG3D_JS-->" in html, "template missing FG3D_JS placeholder"
    assert "<!--TOFUGRAPH:THREE_LOADER-->" in html, "template missing THREE_LOADER placeholder"
    assert "<!--TOFUGRAPH:GRAPH_DATA-->" in html, "template missing GRAPH_DATA placeholder"

    html = html.replace("<!--TOFUGRAPH:FG3D_JS-->", f"<script>\n{fg3d_js}\n</script>")
    html = html.replace("<!--TOFUGRAPH:THREE_LOADER-->", three_loader)
    html = html.replace("<!--TOFUGRAPH:GRAPH_DATA-->", data_block)

    tmp = out_path + ".tmp"
    with open(tmp, "w") as f:
        f.write(html)
    os.replace(tmp, out_path)
    return {
        "out": out_path,
        "size_bytes": os.path.getsize(out_path),
        "nodes": len(parsed.get("nodes", [])),
        "links": len(parsed.get("links", [])),
    }


def main():
    ap = argparse.ArgumentParser(description="tofugraph viz — build the single-file 3D viewer HTML")
    ap.add_argument("--data", default=None, help="exported graph json (default: env TOFUGRAPH_OUT, else ./graph3d-data.json)")
    ap.add_argument("--out", default=None, help="output html path (default: env TOFUGRAPH_VIZ_OUT, else ./graph3d.html)")
    args = ap.parse_args()

    data_path = resolve_data(args.data)
    out_path = resolve_out(args.out)
    result = build(data_path, out_path)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
