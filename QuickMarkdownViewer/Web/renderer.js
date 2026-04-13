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

  let currentSource = "";
  let syntaxHighlightingEnabled = false;
  let syntaxHighlightTheme = "github";
  const highlightThemeStyleIDs = {
    github: "qmv-highlight-theme-github",
    vscode: "qmv-highlight-theme-vscode",
    atomOne: "qmv-highlight-theme-atom-one",
    stackOverflow: "qmv-highlight-theme-stackoverflow"
  };

  function resolveSyntaxHighlightTheme(value) {
    if (typeof value !== "string") {
      return "github";
    }

    const trimmed = value.trim();
    if (Object.prototype.hasOwnProperty.call(highlightThemeStyleIDs, trimmed)) {
      return trimmed;
    }

    return "github";
  }

  function applySyntaxThemeStyleState(theme) {
    const resolvedTheme = resolveSyntaxHighlightTheme(theme);
    syntaxHighlightTheme = resolvedTheme;

    Object.entries(highlightThemeStyleIDs).forEach(([themeKey, styleID]) => {
      const styleElement = document.getElementById(styleID);
      if (!styleElement) {
        return;
      }

      styleElement.disabled = themeKey !== resolvedTheme;
    });
  }

  // Applies highlight.js to all fenced code blocks inside one container.
  function applySyntaxHighlighting(container) {
    if (!syntaxHighlightingEnabled || !window.hljs || !container) {
      return;
    }

    const codeBlocks = container.querySelectorAll("pre code");
    codeBlocks.forEach((block) => {
      window.hljs.highlightElement(block);
    });
  }

  // Renders currently stored Markdown source into the content container.
  function renderCurrentSource(preserveScrollPosition = false) {
    const container = document.getElementById("content");
    if (!container) {
      return;
    }

    const x = preserveScrollPosition ? window.scrollX : 0;
    const y = preserveScrollPosition ? window.scrollY : 0;
    container.innerHTML = renderer.render(currentSource);
    applySyntaxHighlighting(container);

    if (preserveScrollPosition) {
      window.requestAnimationFrame(() => {
        window.scrollTo(x, y);
      });
    }
  }

  // Renders source Markdown and writes HTML into the fixed content container.
  function renderFromSource(markdownSource, options = {}) {
    currentSource = typeof markdownSource === "string" ? markdownSource : "";
    syntaxHighlightingEnabled = !!options.syntaxHighlightingEnabled;
    applySyntaxThemeStyleState(options.syntaxHighlightingTheme);
    renderCurrentSource(false);
  }

  // Enables/disables syntax highlighting and reapplies rendering in place.
  function setSyntaxHighlightingEnabled(enabled) {
    const nextEnabled = !!enabled;
    if (syntaxHighlightingEnabled === nextEnabled) {
      return;
    }

    syntaxHighlightingEnabled = nextEnabled;
    renderCurrentSource(true);
  }

  // Switches syntax theme family and reapplies highlights in place if needed.
  function setSyntaxTheme(theme) {
    const nextTheme = resolveSyntaxHighlightTheme(theme);
    if (syntaxHighlightTheme === nextTheme) {
      return;
    }

    applySyntaxThemeStyleState(nextTheme);
    if (syntaxHighlightingEnabled) {
      renderCurrentSource(true);
    }
  }

  // Expose a tiny, deterministic API used by the HTML bootstrap script.
  window.QuickMarkdownViewerRenderer = {
    renderFromSource,
    setSyntaxHighlightingEnabled,
    setSyntaxTheme
  };
})();
