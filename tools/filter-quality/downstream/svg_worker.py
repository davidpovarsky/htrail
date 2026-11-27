#!/usr/bin/env python3
"""Bounded SVG renderer: no network or arbitrary file resources, no dynamic SVG."""
from __future__ import annotations
import base64, io, math, re, resource, socket, sys
from pathlib import Path
MAX_INPUT=1048576
MAX_PIXELS=1048576
MAX_SIDE=1024
def deny_network(*args,**kwargs):raise ValueError("network-denied")
def main():
    resource.setrlimit(resource.RLIMIT_AS,(512*1024*1024,512*1024*1024))
    resource.setrlimit(resource.RLIMIT_CPU,(3,4))
    resource.setrlimit(resource.RLIMIT_NOFILE,(64,64))
    sys.path.insert(0,str(Path(__file__).resolve().parents[1]/".vendor-svg"))
    from defusedxml import ElementTree
    from PIL import Image
    import tinycss2
    from cairosvg.surface import PNGSurface
    socket.socket=deny_network
    data=sys.stdin.buffer.read(MAX_INPUT+1)
    if len(data)>MAX_INPUT:raise ValueError("svg-input-limit")
    if b"<?xml-stylesheet"in data.lower():raise ValueError("external-stylesheet")
    root=ElementTree.fromstring(data,forbid_dtd=True,forbid_entities=True,forbid_external=True)
    local=lambda name:name.rsplit("}",1)[-1]
    svg_ns="http://www.w3.org/2000/svg"
    if root.tag not in {"svg","{"+svg_ns+"}svg"}:raise ValueError("not-svg")
    metadata_ns={"http://creativecommons.org/ns#","http://purl.org/dc/elements/1.1/","http://www.w3.org/1999/02/22-rdf-syntax-ns#","http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd","http://www.inkscape.org/namespaces/inkscape"}
    supported_tags=set("svg g defs title desc metadata path rect circle ellipse line polyline polygon text tspan textPath linearGradient radialGradient stop clipPath use symbol image style".split())
    props=set("fill fill-opacity fill-rule stroke stroke-width stroke-linecap stroke-linejoin stroke-miterlimit stroke-dasharray stroke-dashoffset stroke-opacity opacity color display visibility font-family font-size font-style font-weight font-variant text-anchor letter-spacing word-spacing text-decoration dominant-baseline alignment-baseline clip-path clip-rule stop-color stop-opacity shape-rendering text-rendering image-rendering".split())
    attrs=set("id class style width height x y x1 x2 y1 y2 cx cy r rx ry d points transform viewBox preserveAspectRatio href version gradientUnits gradientTransform spreadMethod offset fx fy fr clipPathUnits dx dy rotate textLength lengthAdjust space lang".split())|props
    inline={}
    normalized_compositing=False
    blocked={"script","foreignObject","iframe","object","embed","audio","video","animate","animateMotion","animateTransform","set","discard","switch"}
    def check_tokens(tokens):
        for t in tokens:
            if t.type=="error":raise ValueError("invalid-css")
            if t.type=="url":
                if not re.fullmatch(r"#[A-Za-z_][A-Za-z0-9_.:-]*",t.value):raise ValueError("external-css-resource")
            if t.type=="function":
                if t.lower_name=="url":
                    value=tinycss2.serialize(t.arguments).strip().strip("'\"")
                    if not re.fullmatch(r"#[A-Za-z_][A-Za-z0-9_.:-]*",value):raise ValueError("external-css-resource")
                elif t.lower_name not in {"rgb","rgba","hsl","hsla","matrix","translate","scale","rotate","skewx","skewy"}:raise ValueError("unsupported-css-function")
                check_tokens(t.arguments)
            if hasattr(t,"content")and t.content is not None:check_tokens(t.content)
    def declarations(values):
        nonlocal normalized_compositing
        for d in tinycss2.parse_declaration_list(values,skip_comments=True,skip_whitespace=True):
            if d.type!="declaration":raise ValueError("unsupported-css")
            if d.lower_name in {"isolation","mix-blend-mode"}:
                allowed={"auto","isolate"}if d.lower_name=="isolation"else{"normal","multiply"}
                if tinycss2.serialize(d.value).strip().lower()not in allowed:raise ValueError("unsupported-compositing-mode")
                normalized_compositing=True
            elif d.lower_name not in props:raise ValueError("unsupported-css-property")
            check_tokens(d.value)
    stack=[(root,0)];nodes=uses=path_chars=0
    while stack:
        node,depth=stack.pop();nodes+=1
        if nodes>4096 or depth>64:raise ValueError("svg-tree-limit")
        tag=local(node.tag)
        namespace=node.tag[1:].split("}",1)[0]if node.tag.startswith("{")else svg_ns
        if tag in blocked:raise ValueError("dynamic-or-unsupported-svg")
        if namespace not in metadata_ns and (namespace!=svg_ns or tag not in supported_tags):raise ValueError("unsupported-svg-tag")
        if tag=="use":
            uses+=1
            if uses>256:raise ValueError("svg-use-limit")
        if tag=="style":
            for rule in tinycss2.parse_stylesheet(node.text or "",skip_comments=True,skip_whitespace=True):
                if rule.type!="qualified-rule":raise ValueError("css-at-rule-denied")
                if ":"in tinycss2.serialize(rule.prelude):raise ValueError("dynamic-css-selector")
                check_tokens(rule.prelude);declarations(rule.content)
        for raw,value in node.attrib.items():
            attr=local(raw);lower=attr.lower()
            if lower.startswith("on")or lower in {"base","systemlanguage","requiredfeatures","requiredextensions"}:raise ValueError("dynamic-svg-attribute")
            attr_namespace=raw[1:].split("}",1)[0]if raw.startswith("{")else ""
            if namespace==svg_ns and attr_namespace not in metadata_ns and attr not in attrs:raise ValueError("unsupported-svg-attribute")
            if attr=="d":
                path_chars+=len(value)
                if len(value)>100000 or path_chars>200000:raise ValueError("svg-path-limit")
            if attr=="style":declarations(value)
            else:check_tokens(tinycss2.parse_component_value_list(value))
            if lower in {"href","src"}:
                if value.startswith("#"):continue
                if tag!="image":raise ValueError("external-resource-denied")
                match=re.fullmatch(r"data:(image/(?:png|jpeg|webp));base64,([A-Za-z0-9+/=\s]+)",value)
                if not match:raise ValueError("external-or-unsupported-image")
                blob=base64.b64decode(re.sub(r"\s","",match.group(2)),validate=True)
                if len(blob)>768*1024:raise ValueError("embedded-image-byte-limit")
                with Image.open(io.BytesIO(blob))as im:
                    if im.format not in {"PNG","JPEG","WEBP"}or im.width*im.height>4194304 or max(im.size)>4096:raise ValueError("embedded-image-pixel-limit")
                    if getattr(im,"n_frames",1)!=1:raise ValueError("embedded-animation-denied")
                    im.verify()
                inline[value]=blob
        stack.extend((child,depth+1)for child in node)
    def dimension(value,fallback):
        if value is None or "%"in value:return fallback
        match=re.fullmatch(r"\s*([+\-]?(?:\d*\.)?\d+(?:[eE][+\-]?\d+)?)\s*(px|pt|pc|mm|cm|in|em|ex)?\s*",value)
        if not match:raise ValueError("unsupported-svg-dimension")
        number=float(match.group(1))*{"px":1,"pt":96/72,"pc":16,"mm":96/25.4,"cm":96/2.54,"in":96,"em":16,"ex":8,None:1}[match.group(2)]
        if not math.isfinite(number)or number<=0 or number>16384:raise ValueError("svg-dimension-limit")
        return number
    viewbox=root.get("viewBox")
    fallback=(300,150)
    if viewbox:
        values=[float(v)for v in re.split(r"[\s,]+",viewbox.strip())]
        if len(values)!=4 or any(not math.isfinite(v)or abs(v)>16384 for v in values)or min(values[2:])<=0:raise ValueError("svg-viewbox-limit")
        fallback=values[2:]
    width=dimension(root.get("width"),fallback[0]);height=dimension(root.get("height"),fallback[1])
    scale=min(1,MAX_SIDE/max(width,height),math.sqrt(MAX_PIXELS/(width*height)))
    w,h=max(1,round(width*scale)),max(1,round(height*scale))
    def fetch_inline_only(url,resource_type):
        if url in inline:return inline[url]
        raise ValueError("resource-fetch-denied")
    png=PNGSurface.convert(bytestring=data,unsafe=False,url_fetcher=fetch_inline_only,
        output_width=w,output_height=h,parent_width=width,parent_height=height,background_color="#ffffff")
    if len(png)>4194304:raise ValueError("raster-byte-limit")
    with Image.open(io.BytesIO(png))as im:
        if im.width*im.height>MAX_PIXELS:raise ValueError("raster-pixel-limit")
        im.verify()
    if normalized_compositing:sys.stderr.write("PURELINE_RASTERIZED_ALLOW\n")
    sys.stdout.buffer.write(png)
if __name__=="__main__":
    try:main()
    except BaseException as error:
        # Never emit URLs, SVG text, resource paths, or document contents.
        sys.stderr.write(type(error).__name__+"\n")
        raise SystemExit(2)
