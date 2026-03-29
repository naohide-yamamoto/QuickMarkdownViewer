(() => {
  // Configure markdown-it for plain reading output.
  //
  // Key choices:
  // - `html: false` prevents raw HTML passthrough from Markdown input.
  // - `linkify: true` auto-detects plain URLs.
  // - Tables + strikethrough are enabled for expected modern Markdown support.
  const renderer = window.markdownit({
    html: false,
    linkify: true,
    breaks: false,
    typographer: false
  }).enable(["table", "strikethrough"]);

  // Renders source Markdown and writes HTML into the fixed content container.
  function renderFromSource(markdownSource) {
    const source = typeof markdownSource === "string" ? markdownSource : "";
    const html = renderer.render(source);

    const container = document.getElementById("content");
    if (container) {
      container.innerHTML = html;
    }
  }

  // Expose a tiny, deterministic API used by the HTML bootstrap script.
  window.QuickMarkdownViewerRenderer = {
    renderFromSource
  };
})();
