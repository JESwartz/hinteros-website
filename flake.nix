{
  description = "HinterOS.org: the project website";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The launcher's browser demo. Its own nixpkgs pins the Flutter version it is tested with.
    hinteros-launcher.url = "git+https://git.hinteros.org/hinteros-launcher.git?ref=web-demo";
    # The user documentation: Markdown pages, rendered to /docs/.
    hinteros-docs = {
      url = "git+https://git.hinteros.org/hinteros-docs.git";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      hinteros-launcher,
      hinteros-docs,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      python = pkgs.python3.withPackages (ps: [ ps.markdown ]);

      # Atkinson Hyperlegible, the launcher's typeface, as woff2 for the web.
      fonts =
        pkgs.runCommand "hinteros-site-fonts"
          {
            nativeBuildInputs = [
              pkgs.python3Packages.fonttools
              pkgs.python3Packages.brotli
            ];
          }
          ''
            mkdir -p $out
            for f in Regular Bold; do
              fonttools ttLib.woff2 compress -o $out/AtkinsonHyperlegible-$f.woff2 \
                ${pkgs.atkinson-hyperlegible}/share/fonts/opentype/AtkinsonHyperlegible-$f.otf
            done
            cp ${./src/OFL.txt} $out/OFL.txt
          '';

      src = pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions [
          ./build.py
          ./src
        ];
      };

      # The launcher's browser build (base href /demo/), copied verbatim to /demo/. Set it to null
      # to build the site without it: the Try it page then says the demo is on its way.
      demo = hinteros-launcher.packages.${system}.web-demo;

      # The launcher screenshots from hinteros-docs (images/*.png, 1920x1080), as WebP at two
      # widths for the home page: /img/shots/<name>-960.webp and <name>-1600.webp.
      shots = pkgs.runCommand "hinteros-site-shots" { nativeBuildInputs = [ pkgs.libwebp ]; } ''
        mkdir -p $out
        for f in ${hinteros-docs}/images/*.png; do
          n=$(basename "$f" .png)
          for w in 960 1600; do
            cwebp -quiet -q 82 -resize $w 0 "$f" -o "$out/$n-$w.webp"
          done
        done
      '';

      mkSite =
        { release, preview }:
        pkgs.runCommand (if preview then "hinteros-site-preview" else "hinteros-site") { } ''
          ${python}/bin/python3 ${src}/build.py --release ${release} --docs ${hinteros-docs} \
            --shots ${shots} --out $out \
            --fonts ${fonts} ${pkgs.lib.optionalString (demo != null) "--demo ${demo}"} \
            ${pkgs.lib.optionalString preview "--preview"}
        '';

      publish-iso = pkgs.writeShellApplication {
        name = "publish-iso";
        runtimeInputs = with pkgs; [
          git
          openssh
          jq
          coreutils
          findutils
          gnused
          gnugrep
          gawk
        ];
        text = builtins.readFile ./scripts/publish-iso.sh;
      };
    in
    {
      packages.${system} = {
        # The same site with release.example.json, kept out of search engines.
        preview = mkSite {
          release = ./release.example.json;
          preview = true;
        };
        inherit publish-iso;
        default = self.packages.${system}.preview;
      }
      # The real site needs ./release.json, written by publish-iso for a signed stable release.
      // nixpkgs.lib.optionalAttrs (builtins.pathExists ./release.json) {
        site = mkSite {
          release = ./release.json;
          preview = false;
        };
      };

      apps.${system} = {
        publish-iso = {
          type = "app";
          program = "${publish-iso}/bin/publish-iso";
        };
        # `nix run .#serve`: the preview on http://localhost:8000. Store files all have the same
        # 1970 mtime, so a browser revalidating after a rebuild would get 304 and keep stale
        # files: the server ignores If-Modified-Since and tells it not to cache.
        serve = {
          type = "app";
          program = "${pkgs.writers.writePython3 "serve" { flakeIgnore = [ "E501" ]; } ''
            import functools
            import http.server


            class Handler(http.server.SimpleHTTPRequestHandler):
                def send_head(self):
                    del self.headers["If-Modified-Since"]
                    return super().send_head()

                def end_headers(self):
                    self.send_header("Cache-Control", "no-store")
                    super().end_headers()


            print("http://localhost:8000", flush=True)
            http.server.ThreadingHTTPServer(
                ("", 8000),
                functools.partial(
                    Handler, directory="${self.packages.${system}.preview}"
                ),
            ).serve_forever()
          ''}";
        };
      };

      checks.${system} = {
        preview = self.packages.${system}.preview;
        publish-iso = pkgs.runCommand "publish-iso-check" {
          nativeBuildInputs = [
            publish-iso
          ]
          ++ (with pkgs; [
            git
            openssh
            jq
          ]);
        } (builtins.readFile ./scripts/publish-iso-test.sh);
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          python
          pkgs.wrangler
          pkgs.jq
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
