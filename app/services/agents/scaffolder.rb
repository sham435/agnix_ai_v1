# frozen_string_literal: true

require "securerandom"

module Agents
  # Lays down a complete, runnable project from a curated template in a single
  # tool call, then PROVES it works before reporting success.
  #
  # This exists to fix the two things that burned the chat agent's whole
  # iteration budget on the "build me a Django landing page" request:
  #
  #   * Interpreter ambiguity. Several pythons live on this machine and only
  #     some can `import django`. We probe candidate interpreters, PIN the one
  #     that actually imports Django (via its own sys.executable), and hand
  #     back a run command that uses that absolute path — never a bare
  #     `python3` that might resolve to a Django-less interpreter.
  #   * Multi-step file authoring. Writing a whole Django project by hand
  #     through read/write/run round-trips eats dozens of iterations. Here the
  #     entire tree lands in one call.
  #
  # Safety: every file is written through Agents::OsExecutor.write_file, so the
  # same allowed-roots / app-tree-blocked guardrails as the raw write tool
  # apply; a path the agent could not write with write_file it cannot write
  # here either.
  class Scaffolder
    TEMPLATES = %w[django_landing].freeze

    # Ordered interpreters probed for a working `import django`. The first that
    # succeeds is pinned. SHAMS_SCAFFOLD_PYTHON, when set, is tried first so an
    # operator can pin the interpreter explicitly.
    PYTHON_CANDIDATES = [
      "/usr/bin/python3",
      "/opt/homebrew/bin/python3",
      ".venv/bin/python",
      "python3"
    ].freeze

    # Single-quoted shell argument: prints "<django version>\n<sys.executable>".
    # No single quotes appear inside, so it survives bash -lc wrapping intact.
    PROBE_SNIPPET = %q{'import django,sys; sys.stdout.write(django.get_version()+"\n"+sys.executable)'}

    PROBE_TIMEOUT = 15
    CHECK_TIMEOUT = 30

    class << self
      # Public entry: build + write + probe + verify. Returns a bounded Hash;
      # never raises for expected failures (unknown template, blocked path,
      # empty dir, missing Django, failed check).
      def scaffold(template:, target_dir:, brand: nil, force: false)
        template = template.to_s
        unless TEMPLATES.include?(template)
          return { ok: false, error_code: "unknown_template", template: template,
                   allowed: TEMPLATES }
        end

        target = File.expand_path(target_dir.to_s)
        brand  = sanitize_brand(brand)

        if !force && File.exist?(File.join(target, "manage.py"))
          return { ok: false, error_code: "dir_not_empty", project_dir: target,
                   note: "A manage.py already exists here. Re-run with force: true to overwrite." }
        end

        files = build_files(template, brand: brand)
        written = write_all!(target, files) # raises SecurityError -> rescued below

        interp = probe_interpreter(project_dir: target)
        if interp.nil?
          return { ok: false, error_code: "no_django_interpreter", project_dir: target,
                   files_written: written.length, candidates_tried: candidates,
                   note: "Files are on disk, but no interpreter here can import Django. " \
                         "Install it (pip install -r requirements.txt) or set SHAMS_SCAFFOLD_PYTHON." }
        end

        check = Agents::OsExecutor.run_command("#{interp[:path]} manage.py check",
                                               workdir: target, timeout: CHECK_TIMEOUT)
        unless check[:ok]
          return { ok: false, error_code: "verification_failed", project_dir: target,
                   interpreter: interp[:path], files_written: written.length,
                   check_stdout: clip(check[:stdout]), check_stderr: clip(check[:stderr]) }
        end

        { ok: true, template: template, project_dir: target,
          interpreter: interp[:path], django_version: interp[:version],
          check: clip(check[:stdout]),
          run_command: "#{interp[:path]} manage.py runserver",
          files: written }
      rescue SecurityError => e
        { ok: false, error_code: "blocked_path", error: e.message, project_dir: target }
      end

      # First interpreter (in candidate order) that can `import django`.
      # Returns { path:, version:, command: } with path pinned to the resolved
      # sys.executable (absolute), or nil when none qualify.
      def probe_interpreter(project_dir:)
        candidates.each do |cand|
          res = Agents::OsExecutor.run_command("#{cand} -c #{PROBE_SNIPPET}",
                                               workdir: project_dir, timeout: PROBE_TIMEOUT)
          next unless res[:ok]

          version, path = res[:stdout].to_s.strip.split("\n", 2)
          next if version.to_s.empty? || path.to_s.empty?

          return { path: path.strip, version: version.strip, command: cand }
        end
        nil
      end

      private

      def candidates
        from_env = ENV["SHAMS_SCAFFOLD_PYTHON"].to_s.strip
        ([ from_env ] + PYTHON_CANDIDATES).reject(&:empty?).uniq
      end

      def sanitize_brand(brand)
        cleaned = brand.to_s.strip.gsub(/["\\\n\r\t]/, "").slice(0, 40).to_s.strip
        cleaned.empty? ? "NOVA" : cleaned
      end

      def write_all!(target, files)
        files.map do |rel, content|
          res = Agents::OsExecutor.write_file(File.join(target, rel), content)
          { path: rel, bytes: res[:bytes] }
        end
      end

      def clip(text)
        text.to_s[0, 2_000]
      end

      # rel-path => file content for one template. Only the pieces that vary
      # per run (SECRET_KEY, brand) are interpolated; everything else is a
      # verbatim literal so the Python/HTML indentation stays exact.
      def build_files(template, brand:)
        case template
        when "django_landing" then django_landing_files(brand)
        else {}
        end
      end

      def django_landing_files(brand)
        secret_key = "django-insecure-#{SecureRandom.alphanumeric(50)}"

        {
          "manage.py" => MANAGE_PY,
          "requirements.txt" => "Django>=4.2,<5.0\n",
          ".gitignore" => GITIGNORE,
          "README.md" => readme(brand),
          "config/__init__.py" => "",
          "config/settings.py" => settings_py(secret_key),
          "config/urls.py" => URLS_PY,
          "config/wsgi.py" => WSGI_PY,
          "config/asgi.py" => ASGI_PY,
          "landing/__init__.py" => "",
          "landing/apps.py" => LANDING_APPS_PY,
          "landing/models.py" => LANDING_MODELS_PY,
          "landing/admin.py" => LANDING_ADMIN_PY,
          "landing/tests.py" => LANDING_TESTS_PY,
          "landing/urls.py" => LANDING_URLS_PY,
          "landing/views.py" => landing_views_py(brand),
          "landing/migrations/__init__.py" => "",
          "landing/templates/landing/home.html" => HOME_HTML
        }
      end

      def readme(brand)
        <<~MD
          # #{brand} — Django single-page landing

          Self-contained futuristic landing page (no external assets, no build step).

          ## Run

          The interpreter must be able to `import django`. The scaffold tool pinned
          one that can — use that exact binary:

          ```bash
          ./manage.py runserver
          # then open http://127.0.0.1:8000/
          ```

          If starting fresh in a new shell, install dependencies first:

          ```bash
          python3 -m pip install -r requirements.txt
          ```

          ## Edit the copy
          All headline / feature / CTA text lives in `landing/views.py` (the
          `content` dict). Layout and styling live in
          `landing/templates/landing/home.html`.
        MD
      end

      def settings_py(secret_key)
        <<~PY
          """
          Django settings for the scaffolded single-page landing project.
          """

          from pathlib import Path

          BASE_DIR = Path(__file__).resolve().parent.parent

          SECRET_KEY = "#{secret_key}"

          DEBUG = True

          ALLOWED_HOSTS = ["localhost", "127.0.0.1", "[::1]", "0.0.0.0"]

          INSTALLED_APPS = [
              "django.contrib.admin",
              "django.contrib.auth",
              "django.contrib.contenttypes",
              "django.contrib.sessions",
              "django.contrib.messages",
              "django.contrib.staticfiles",
              "landing",
          ]

          MIDDLEWARE = [
              "django.middleware.security.SecurityMiddleware",
              "django.contrib.sessions.middleware.SessionMiddleware",
              "django.middleware.common.CommonMiddleware",
              "django.middleware.csrf.CsrfViewMiddleware",
              "django.contrib.auth.middleware.AuthenticationMiddleware",
              "django.contrib.messages.middleware.MessageMiddleware",
              "django.middleware.clickjacking.XFrameOptionsMiddleware",
          ]

          ROOT_URLCONF = "config.urls"

          TEMPLATES = [
              {
                  "BACKEND": "django.template.backends.django.DjangoTemplates",
                  "DIRS": [],
                  "APP_DIRS": True,
                  "OPTIONS": {
                      "context_processors": [
                          "django.template.context_processors.debug",
                          "django.template.context_processors.request",
                          "django.contrib.auth.context_processors.auth",
                          "django.contrib.messages.context_processors.messages",
                      ],
                  },
              },
          ]

          WSGI_APPLICATION = "config.wsgi.application"

          DATABASES = {
              "default": {
                  "ENGINE": "django.db.backends.sqlite3",
                  "NAME": BASE_DIR / "db.sqlite3",
              }
          }

          AUTH_PASSWORD_VALIDATORS = [
              {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
              {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
              {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
              {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
          ]

          LANGUAGE_CODE = "en-us"
          TIME_ZONE = "UTC"
          USE_I18N = True
          USE_TZ = True

          STATIC_URL = "static/"

          DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
        PY
      end

      def landing_views_py(brand)
        <<~PY
          from django.shortcuts import render


          def home(request):
              """Render the single-page landing.

              Copy is served from a small content dict so the owner can tune the
              message without touching the template markup.
              """
              content = {
                  "brand": "#{brand}",
                  "tagline": "Ship intelligent products at the speed of thought.",
                  "subtitle": (
                      "#{brand} turns a one-line idea into a working, deployed "
                      "application - planning, scaffolding, coding and verifying "
                      "autonomously."
                  ),
                  "primary_cta": "Start building free",
                  "secondary_cta": "Watch the 2-min demo",
                  "features": [
                      {
                          "title": "Autonomous planning",
                          "body": "Breaks a fuzzy goal into verified steps and executes them end to end.",
                          "icon": "\\u25c6",
                      },
                      {
                          "title": "Real tool use",
                          "body": "Runs commands, edits files and calls APIs on your machine - safely.",
                          "icon": "\\u2b22",
                      },
                      {
                          "title": "Self-healing builds",
                          "body": "Reads errors, patches them and re-verifies until the test suite is green.",
                          "icon": "\\u25b2",
                      },
                      {
                          "title": "Hot templates",
                          "body": "Instantly scaffolds proven stacks instead of starting every project from scratch.",
                          "icon": "\\u2726",
                      },
                  ],
                  "stats": [
                      {"value": "10x", "label": "faster to first commit"},
                      {"value": "98%", "label": "builds verified green"},
                      {"value": "24/7", "label": "autonomous agents"},
                  ],
              }
              return render(request, "landing/home.html", content)
        PY
      end

      MANAGE_PY = <<~'PY'
        #!/usr/bin/env python
        """Django's command-line utility for administrative tasks."""

        import os
        import sys


        def main():
            """Run administrative tasks."""
            os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
            try:
                from django.core.management import execute_from_command_line
            except ImportError as exc:
                raise ImportError(
                    "Couldn't import Django. Are you sure it's installed and "
                    "available on your PYTHONPATH environment variable? Did you "
                    "forget to activate a virtual environment?"
                ) from exc
            execute_from_command_line(sys.argv)


        if __name__ == "__main__":
            main()
      PY

      URLS_PY = <<~'PY'
        """URL configuration for the scaffolded project."""

        from django.contrib import admin
        from django.urls import include, path

        urlpatterns = [
            path("admin/", admin.site.urls),
            path("", include("landing.urls")),
        ]
      PY

      WSGI_PY = <<~'PY'
        """WSGI config for the scaffolded project."""

        import os

        from django.core.wsgi import get_wsgi_application

        os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

        application = get_wsgi_application()
      PY

      ASGI_PY = <<~'PY'
        """ASGI config for the scaffolded project."""

        import os

        from django.core.asgi import get_asgi_application

        os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

        application = get_asgi_application()
      PY

      LANDING_APPS_PY = <<~'PY'
        from django.apps import AppConfig


        class LandingConfig(AppConfig):
            default_auto_field = "django.db.models.BigAutoField"
            name = "landing"
      PY

      LANDING_URLS_PY = <<~'PY'
        from django.urls import path

        from . import views

        app_name = "landing"

        urlpatterns = [
            path("", views.home, name="home"),
        ]
      PY

      LANDING_MODELS_PY = <<~'PY'
        from django.db import models

        # Create your models here.
      PY

      LANDING_ADMIN_PY = <<~'PY'
        from django.contrib import admin

        # Register your models here.
      PY

      LANDING_TESTS_PY = <<~'PY'
        from django.test import TestCase

        # Create your tests here.
      PY

      GITIGNORE = <<~'TXT'
        db.sqlite3
        __pycache__/
        *.py[cod]
        .venv/
        staticfiles/
      TXT

      # Verbatim single-file landing page. Non-interpolating heredoc: the whole
      # page is literal Django-template + CSS + JS, authored exactly as verified.
      HOME_HTML = <<~'HTML'
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>{{ brand }} — {{ tagline }}</title>
            <meta name="description" content="{{ subtitle }}" />
            <style>
              :root {
                --bg: #05060b;
                --bg-2: #0a0d18;
                --fg: #e7ecff;
                --muted: #9aa4c4;
                --accent: #6a5cff;
                --accent-2: #21e6c1;
                --glow: #6a5cff55;
                --card: #ffffff0a;
                --border: #ffffff1f;
                --radius: 18px;
              }

              * { box-sizing: border-box; margin: 0; padding: 0; }

              html { scroll-behavior: smooth; }

              body {
                font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto,
                  Inter, sans-serif;
                color: var(--fg);
                background:
                  radial-gradient(60% 60% at 15% 0%, #1a1140 0%, transparent 60%),
                  radial-gradient(50% 50% at 90% 10%, #06302a 0%, transparent 55%),
                  linear-gradient(180deg, var(--bg) 0%, var(--bg-2) 100%);
                min-height: 100vh;
                line-height: 1.6;
                -webkit-font-smoothing: antialiased;
                overflow-x: hidden;
              }

              /* Animated aurora backdrop */
              .aurora {
                position: fixed;
                inset: -20% -20% auto -20%;
                height: 70vh;
                filter: blur(90px);
                opacity: 0.5;
                pointer-events: none;
                z-index: 0;
                background:
                  conic-gradient(from 0deg at 30% 40%, #6a5cff, #21e6c1, #ff4d8d, #6a5cff);
                animation: spin 26s linear infinite;
              }
              @keyframes spin { to { transform: rotate(1turn); } }
              @media (prefers-reduced-motion: reduce) {
                .aurora { animation: none; }
                html { scroll-behavior: auto; }
              }

              .wrap { position: relative; z-index: 1; max-width: 1120px; margin: 0 auto; padding: 0 24px; }

              /* Nav */
              header.nav {
                display: flex; align-items: center; justify-content: space-between;
                padding: 26px 0;
              }
              .logo {
                display: flex; align-items: center; gap: 10px;
                font-weight: 800; letter-spacing: 0.14em; font-size: 15px;
              }
              .logo .dot {
                width: 14px; height: 14px; border-radius: 50%;
                background: linear-gradient(135deg, var(--accent), var(--accent-2));
                box-shadow: 0 0 22px var(--glow);
              }
              nav.links { display: flex; gap: 26px; }
              nav.links a { color: var(--muted); text-decoration: none; font-size: 14px; transition: color .18s; }
              nav.links a:hover { color: var(--fg); }
              @media (max-width: 640px) { nav.links { display: none; } }

              /* Hero */
              .hero { text-align: center; padding: 90px 0 60px; }
              .eyebrow {
                display: inline-flex; align-items: center; gap: 8px;
                padding: 6px 14px; border: 1px solid var(--border); border-radius: 999px;
                background: var(--card); color: var(--muted); font-size: 12.5px;
                letter-spacing: .04em; backdrop-filter: blur(8px);
              }
              .eyebrow b { color: var(--accent-2); font-weight: 600; }
              h1 {
                margin: 22px auto 0; max-width: 16ch;
                font-size: clamp(38px, 7vw, 74px); line-height: 1.03; font-weight: 800;
                letter-spacing: -0.02em;
                background: linear-gradient(180deg, #fff, #b9c2ff);
                -webkit-background-clip: text; background-clip: text; color: transparent;
              }
              .sub { margin: 20px auto 0; max-width: 60ch; color: var(--muted); font-size: clamp(16px, 2.4vw, 19px); }

              .cta { margin-top: 34px; display: flex; gap: 14px; justify-content: center; flex-wrap: wrap; }
              .btn {
                --pad: 14px 22px;
                display: inline-flex; align-items: center; gap: 9px; padding: var(--pad);
                border-radius: 12px; font-weight: 600; font-size: 15px; text-decoration: none;
                transition: transform .15s ease, box-shadow .2s ease, background .2s;
              }
              .btn:active { transform: translateY(1px) scale(.99); }
              .btn-primary {
                color: #06040f;
                background: linear-gradient(135deg, var(--accent-2), var(--accent));
                box-shadow: 0 10px 40px var(--glow);
              }
              .btn-primary:hover { box-shadow: 0 14px 54px var(--glow); transform: translateY(-2px); }
              .btn-ghost { color: var(--fg); border: 1px solid var(--border); background: var(--card); }
              .btn-ghost:hover { background: #ffffff14; }

              /* Stats */
              .stats {
                margin: 60px auto 0; display: grid; grid-template-columns: repeat(3, 1fr);
                gap: 20px; max-width: 760px;
              }
              .stat {
                text-align: center; padding: 22px; border: 1px solid var(--border);
                border-radius: var(--radius); background: var(--card); backdrop-filter: blur(8px);
              }
              .stat .v {
                font-size: 34px; font-weight: 800;
                background: linear-gradient(135deg, var(--accent-2), var(--accent));
                -webkit-background-clip: text; background-clip: text; color: transparent;
              }
              .stat .l { color: var(--muted); font-size: 13.5px; }

              /* Features */
              .section-title { text-align: center; margin: 90px 0 8px; font-size: clamp(26px, 4vw, 40px); font-weight: 800; letter-spacing: -.01em; }
              .section-lead { text-align: center; color: var(--muted); max-width: 56ch; margin: 0 auto 40px; }
              .grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 20px; }
              @media (max-width: 720px) { .grid, .stats { grid-template-columns: 1fr; } }
              .card {
                padding: 28px; border: 1px solid var(--border); border-radius: var(--radius);
                background: linear-gradient(180deg, #ffffff0d, #ffffff05); backdrop-filter: blur(10px);
                transition: transform .2s ease, border-color .2s ease;
              }
              .card:hover { transform: translateY(-4px); border-color: #ffffff3a; }
              .card .ic {
                width: 46px; height: 46px; display: grid; place-items: center; font-size: 20px;
                border-radius: 12px; color: var(--accent-2);
                background: #21e6c11a; border: 1px solid #21e6c133; margin-bottom: 16px;
              }
              .card h3 { font-size: 19px; margin-bottom: 8px; }
              .card p { color: var(--muted); font-size: 15px; }

              /* Big CTA */
              .band {
                margin: 100px 0; text-align: center; padding: 56px 28px; border-radius: 26px;
                border: 1px solid var(--border);
                background:
                  radial-gradient(120% 120% at 50% -10%, #6a5cff2b, transparent 60%),
                  linear-gradient(180deg, #ffffff0d, #ffffff04);
                backdrop-filter: blur(10px);
              }
              .band h2 { font-size: clamp(24px, 4vw, 38px); margin-bottom: 12px; }
              .band p { color: var(--muted); margin-bottom: 26px; }

              /* Footer */
              footer {
                border-top: 1px solid var(--border); padding: 34px 0 60px;
                display: flex; align-items: center; justify-content: space-between; gap: 16px;
                color: var(--muted); font-size: 13.5px; flex-wrap: wrap;
              }
              footer .fl { display: flex; gap: 20px; }
              footer a { color: var(--muted); text-decoration: none; }
              footer a:hover { color: var(--fg); }
            </style>
          </head>
          <body>
            <div class="aurora" aria-hidden="true"></div>

            <div class="wrap">
              <header class="nav">
                <div class="logo"><span class="dot"></span>{{ brand }}</div>
                <nav class="links">
                  <a href="#features">Features</a>
                  <a href="#how">Why {{ brand }}</a>
                  <a href="#start">Pricing</a>
                </nav>
                <a class="btn btn-primary" href="#start">{{ primary_cta }}</a>
              </header>

              <section class="hero">
                <span class="eyebrow">✦ <b>Autonomous</b> product engineering</span>
                <h1>{{ tagline }}</h1>
                <p class="sub">{{ subtitle }}</p>
                <div class="cta">
                  <a class="btn btn-primary" href="#start">{{ primary_cta }} →</a>
                  <a class="btn btn-ghost" href="#how">{{ secondary_cta }}</a>
                </div>

                <div class="stats">
                  {% for s in stats %}
                  <div class="stat">
                    <div class="v">{{ s.value }}</div>
                    <div class="l">{{ s.label }}</div>
                  </div>
                  {% endfor %}
                </div>
              </section>

              <section id="features">
                <h2 class="section-title">Everything you need to go from idea → shipped</h2>
                <p class="section-lead">
                  A single agent that plans, writes, runs and verifies — using real tools
                  and battle-tested templates so nothing starts from scratch.
                </p>
                <div class="grid">
                  {% for f in features %}
                  <div class="card">
                    <div class="ic">{{ f.icon }}</div>
                    <h3>{{ f.title }}</h3>
                    <p>{{ f.body }}</p>
                  </div>
                  {% endfor %}
                </div>
              </section>

              <section id="how"></section>

              <section id="start" class="band">
                <h2>Give {{ brand }} one line. Get a working app.</h2>
                <p>Free to start. No credit card. Your first commit is minutes away.</p>
                <a class="btn btn-primary" href="#start">{{ primary_cta }} →</a>
              </section>

              <footer>
                <div class="logo"><span class="dot"></span>{{ brand }}</div>
                <div class="fl">
                  <a href="#">Docs</a>
                  <a href="#">Status</a>
                  <a href="#">Privacy</a>
                  <a href="#">Contact</a>
                </div>
                <div>© {% now "Y" %} {{ brand }}. Built with Django.</div>
              </footer>
            </div>

            <script>
              // Reveal-on-scroll for cards, respecting reduced-motion.
              (function () {
                var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
                if (reduce || !("IntersectionObserver" in window)) return;
                document
                  .querySelectorAll(".card, .stat")
                  .forEach(function (el) {
                    el.style.opacity = "0";
                    el.style.transform = "translateY(14px)";
                    el.style.transition = "opacity .5s ease, transform .5s ease";
                  });
                var io = new IntersectionObserver(
                  function (entries) {
                    entries.forEach(function (e) {
                      if (e.isIntersecting) {
                        e.target.style.opacity = "1";
                        e.target.style.transform = "none";
                        io.unobserve(e.target);
                      }
                    });
                  },
                  { threshold: 0.15 }
                );
                document.querySelectorAll(".card, .stat").forEach(function (el) { io.observe(el); });
              })();
            </script>
          </body>
        </html>
      HTML
    end
  end
end
