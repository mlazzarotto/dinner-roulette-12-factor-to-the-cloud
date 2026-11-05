// Static page served on GET /. Built as a single string so the image needs no
// extra COPY and no template engine. The base URL is filled in by the browser
// from window.location.origin, so the same page works on localhost, minikube
// and OKE.
export const pageHtml = `<!doctype html>
<html lang="it">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Dinner Roulette</title>
  <style>
    :root {
      --bg: #fbfbfa;
      --surface: #ffffff;
      --text: #1a1a18;
      --muted: #6b6b66;
      --border: #e5e5e0;
      --accent: #c2410c;
      --accent-soft: #fdf1e9;
      --code-bg: #f6f6f3;
      --ok: #15803d;
      --err: #b91c1c;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, Helvetica, Arial, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    main {
      max-width: 760px;
      margin: 0 auto;
      padding: 64px 24px 96px;
    }
    header { margin-bottom: 48px; }
    .eyebrow {
      font-size: 12px;
      letter-spacing: 0.14em;
      text-transform: uppercase;
      color: var(--accent);
      font-weight: 600;
      margin: 0 0 12px;
    }
    h1 {
      font-size: 32px;
      line-height: 1.2;
      letter-spacing: -0.02em;
      margin: 0 0 12px;
      font-weight: 600;
    }
    header p { margin: 0; color: var(--muted); max-width: 56ch; }
    .base {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      margin-top: 20px;
      padding: 6px 12px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: var(--surface);
      font-size: 13px;
      color: var(--muted);
    }
    .base code { color: var(--text); font-size: 13px; }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 24px;
      margin-bottom: 16px;
    }
    .card-head {
      display: flex;
      align-items: baseline;
      gap: 10px;
      flex-wrap: wrap;
      margin-bottom: 6px;
    }
    .method {
      font: 600 11px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
      letter-spacing: 0.06em;
      padding: 5px 7px;
      border-radius: 5px;
      background: var(--accent-soft);
      color: var(--accent);
      border: 1px solid #f5dccb;
    }
    .path { font: 600 15px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
    .card > p { margin: 0 0 16px; color: var(--muted); font-size: 14px; }
    .code-block { position: relative; }
    pre {
      margin: 0;
      background: var(--code-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 14px 16px;
      overflow-x: auto;
    }
    pre code {
      font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
      white-space: pre;
      color: var(--text);
    }
    button {
      font: inherit;
      cursor: pointer;
      border-radius: 7px;
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--text);
      padding: 6px 12px;
      font-size: 13px;
      transition: background 0.12s ease, border-color 0.12s ease;
    }
    button:hover { border-color: #d4d4cc; background: #fafaf8; }
    button:active { background: var(--code-bg); }
    .copy {
      position: absolute;
      top: 8px;
      right: 8px;
      font-size: 12px;
      padding: 4px 9px;
      color: var(--muted);
    }
    .primary {
      background: var(--accent);
      border-color: var(--accent);
      color: #fff;
      padding: 8px 16px;
      font-size: 14px;
      font-weight: 500;
    }
    .primary:hover { background: #a8380b; border-color: #a8380b; }
    .primary:disabled { opacity: 0.6; cursor: progress; }
    .result {
      margin-top: 16px;
      padding: 14px 16px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--code-bg);
      font-size: 14px;
      min-height: 20px;
    }
    .result[hidden] { display: none; }
    .result .name { font-weight: 600; }
    .result .meta { color: var(--muted); font-size: 13px; }
    .ok { color: var(--ok); }
    .err { color: var(--err); }
    .ids {
      margin-top: 12px;
      font-size: 13px;
      color: var(--muted);
    }
    .ids code {
      font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
      color: var(--text);
      background: var(--code-bg);
      padding: 2px 6px;
      border-radius: 4px;
      border: 1px solid var(--border);
    }
    footer {
      margin-top: 40px;
      padding-top: 20px;
      border-top: 1px solid var(--border);
      font-size: 13px;
      color: var(--muted);
      display: flex;
      justify-content: space-between;
      gap: 12px;
      flex-wrap: wrap;
    }
    @media (max-width: 520px) {
      main { padding: 40px 18px 64px; }
      h1 { font-size: 26px; }
      .card { padding: 18px; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <p class="eyebrow">Dinner Roulette</p>
      <h1>Dove si cena stasera?</h1>
      <p>Vota un ristorante e lascia che l'app scelga il pi&ugrave; votato per te. Le chiamate qui sotto sono pronte da copiare.</p>
      <span class="base">base url <code id="base-url"></code></span>
    </header>

    <article class="card">
      <div class="card-head">
        <span class="method">POST</span>
        <span class="path">/votes</span>
      </div>
      <p>Registra un voto per un ristorante esistente. Risponde <code>201</code>, <code>400</code> se manca un campo, <code>404</code> se il ristorante non esiste.</p>
      <div class="code-block">
        <pre><code data-curl="curl -X POST {{base}}/votes -H 'Content-Type: application/json' -d '{&quot;user&quot;:&quot;alice&quot;,&quot;restaurantId&quot;:&quot;sakura&quot;}'"></code></pre>
        <button class="copy" type="button">Copia</button>
      </div>
      <div class="ids">ID disponibili: <code>sakura</code> <code>napoli</code> <code>trattoria</code></div>
    </article>

    <article class="card">
      <div class="card-head">
        <span class="method">GET</span>
        <span class="path">/suggestion</span>
      </div>
      <p>Sceglie a caso uno dei ristoranti con pi&ugrave; voti e lo restituisce con il conteggio.</p>
      <div class="code-block">
        <pre><code data-curl="curl {{base}}/suggestion"></code></pre>
        <button class="copy" type="button">Copia</button>
      </div>
      <div style="margin-top: 16px">
        <button class="primary" id="suggest" type="button">Suggerisci un ristorante</button>
      </div>
      <div class="result" id="result" role="status" aria-live="polite" hidden></div>
    </article>

    <article class="card">
      <div class="card-head">
        <span class="method">GET</span>
        <span class="path">/health</span>
      </div>
      <p>Stato del processo. Non tocca il database.</p>
      <div class="code-block">
        <pre><code data-curl="curl {{base}}/health"></code></pre>
        <button class="copy" type="button">Copia</button>
      </div>
    </article>

    <article class="card">
      <div class="card-head">
        <span class="method">GET</span>
        <span class="path">/version</span>
      </div>
      <p>Commit SHA iniettato alla build.</p>
      <div class="code-block">
        <pre><code data-curl="curl {{base}}/version"></code></pre>
        <button class="copy" type="button">Copia</button>
      </div>
    </article>

    <footer>
      <span>Dinner Roulette</span>
      <span id="version"></span>
    </footer>
  </main>

  <script>
    (function () {
      var base = window.location.origin;
      document.getElementById("base-url").textContent = base;

      document.querySelectorAll("code[data-curl]").forEach(function (el) {
        var template = el.getAttribute("data-curl");
        el.textContent = template.split("{{base}}").join(base);
      });

      document.querySelectorAll(".copy").forEach(function (btn) {
        btn.addEventListener("click", function () {
          var code = btn.parentElement.querySelector("code").textContent;
          var done = function () {
            btn.textContent = "Copiato";
            setTimeout(function () { btn.textContent = "Copia"; }, 1500);
          };
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(code).then(done, function () {});
            return;
          }
          var ta = document.createElement("textarea");
          ta.value = code;
          document.body.appendChild(ta);
          ta.select();
          try { document.execCommand("copy"); done(); } catch (e) {}
          document.body.removeChild(ta);
        });
      });

      var result = document.getElementById("result");
      var button = document.getElementById("suggest");

      function render(html, className) {
        result.className = "result " + (className || "");
        result.innerHTML = html;
        result.hidden = false;
      }

      button.addEventListener("click", function () {
        button.disabled = true;
        result.hidden = true;
        fetch(base + "/suggestion")
          .then(function (res) {
            if (!res.ok) {
              throw new Error("l'API ha risposto " + res.status);
            }
            return res.json();
          })
          .then(function (data) {
            if (!data || !data.restaurant) {
              render("Nessun ristorante disponibile. Vota qualcosa prima di chiedere un suggerimento.", "err");
              return;
            }
            var r = data.restaurant;
            render(
              '<span class="name">' + escapeHtml(r.name) + '</span> ' +
              '<span class="meta">&middot; ' + escapeHtml(r.category) + ' &middot; ' + data.votes + ' voti</span>',
              "ok"
            );
          })
          .catch(function (err) {
            render("Non riesco a ottenere un suggerimento: " + escapeHtml(err.message) + ".", "err");
          })
          .then(function () { button.disabled = false; });
      });

      function escapeHtml(value) {
        return String(value).replace(/[&<>"']/g, function (c) {
          return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
        });
      }

      fetch(base + "/version")
        .then(function (res) { return res.json(); })
        .then(function (data) { document.getElementById("version").textContent = "commit " + data.commit; })
        .catch(function () {});
    })();
  </script>
</body>
</html>
`;
