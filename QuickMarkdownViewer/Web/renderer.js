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
  let documentTypeface = "sans-serif";
  let documentDensity = "standard";
  const highlightThemeStyleIDs = {
    github: "qmv-highlight-theme-github",
    vscode: "qmv-highlight-theme-vscode",
    atomOne: "qmv-highlight-theme-atom-one",
    stackOverflow: "qmv-highlight-theme-stackoverflow"
  };
  const documentTypefaceBodyClassPrefix = "qmv-typeface-";
  const supportedDocumentTypefaces = ["sans-serif", "serif"];
  const documentDensityBodyClassPrefix = "qmv-density-";
  const supportedDocumentDensities = ["standard", "compact"];

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

  function resolveDocumentTypeface(value) {
    if (typeof value !== "string") {
      return "sans-serif";
    }

    const trimmed = value.trim().toLowerCase();
    if (supportedDocumentTypefaces.includes(trimmed)) {
      return trimmed;
    }

    return "sans-serif";
  }

  function applyDocumentTypefaceClassState(typeface) {
    const resolvedTypeface = resolveDocumentTypeface(typeface);
    documentTypeface = resolvedTypeface;

    const target = document.body;
    if (!target) {
      return;
    }

    supportedDocumentTypefaces.forEach((typefaceKey) => {
      target.classList.remove(`${documentTypefaceBodyClassPrefix}${typefaceKey}`);
    });

    target.classList.add(`${documentTypefaceBodyClassPrefix}${resolvedTypeface}`);
  }

  function resolveDocumentDensity(value) {
    if (typeof value !== "string") {
      return "standard";
    }

    const trimmed = value.trim().toLowerCase();
    if (supportedDocumentDensities.includes(trimmed)) {
      return trimmed;
    }

    return "standard";
  }

  function applyDocumentDensityClassState(density) {
    const resolvedDensity = resolveDocumentDensity(density);
    documentDensity = resolvedDensity;

    const target = document.body;
    if (!target) {
      return;
    }

    supportedDocumentDensities.forEach((densityKey) => {
      target.classList.remove(`${documentDensityBodyClassPrefix}${densityKey}`);
    });

    target.classList.add(`${documentDensityBodyClassPrefix}${resolvedDensity}`);
  }

  // Applies highlight.js to all fenced code blocks inside one container.
  function applySyntaxHighlighting(container) {
    if (!syntaxHighlightingEnabled || !window.hljs || !container) {
      return;
    }

    const codeBlocks = container.querySelectorAll("pre code");
    codeBlocks.forEach((block) => {
      if (block.classList.contains("hljs") || block.hasAttribute("data-highlighted")) {
        return;
      }
      window.hljs.highlightElement(block);
    });
  }

  // Removes highlight.js token markup in place while preserving plain code text.
  function clearSyntaxHighlighting(container) {
    if (!container) {
      return;
    }

    const codeBlocks = container.querySelectorAll("pre code");
    codeBlocks.forEach((block) => {
      const plainText = block.textContent || "";
      block.textContent = plainText;
      block.classList.remove("hljs");
      block.removeAttribute("data-highlighted");
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
    applyDocumentTypefaceClassState(options.documentTypeface);
    applyDocumentDensityClassState(options.documentDensity);
    renderCurrentSource(false);
  }

  // Enables/disables syntax highlighting and reapplies rendering in place.
  function setSyntaxHighlightingEnabled(enabled) {
    const nextEnabled = !!enabled;
    if (syntaxHighlightingEnabled === nextEnabled) {
      return;
    }

    syntaxHighlightingEnabled = nextEnabled;
    const container = document.getElementById("content");
    if (!container) {
      return;
    }

    if (syntaxHighlightingEnabled) {
      applySyntaxHighlighting(container);
    } else {
      clearSyntaxHighlighting(container);
    }
  }

  // Switches syntax theme family and reapplies highlights in place if needed.
  function setSyntaxTheme(theme) {
    const nextTheme = resolveSyntaxHighlightTheme(theme);
    if (syntaxHighlightTheme === nextTheme) {
      return;
    }

    applySyntaxThemeStyleState(nextTheme);
    if (!syntaxHighlightingEnabled) {
      return;
    }

    const container = document.getElementById("content");
    if (!container) {
      return;
    }

    const hasHighlightedCode = !!container.querySelector(
      "pre code.hljs, pre code[data-highlighted]"
    );
    if (!hasHighlightedCode) {
      applySyntaxHighlighting(container);
    }
  }

  // Switches document typeface without re-rendering Markdown HTML.
  function setDocumentTypeface(typeface) {
    const nextTypeface = resolveDocumentTypeface(typeface);
    if (documentTypeface === nextTypeface) {
      return;
    }

    applyDocumentTypefaceClassState(nextTypeface);
  }

  // Switches document density without re-rendering Markdown HTML.
  function setDocumentDensity(density) {
    const nextDensity = resolveDocumentDensity(density);
    if (documentDensity === nextDensity) {
      return;
    }

    applyDocumentDensityClassState(nextDensity);
  }

  // Expose a tiny, deterministic API used by the HTML bootstrap script.
  window.QuickMarkdownViewerRenderer = {
    renderFromSource,
    setSyntaxHighlightingEnabled,
    setSyntaxTheme,
    setDocumentTypeface,
    setDocumentDensity
  };
})();
