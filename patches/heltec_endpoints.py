    # =========================================================================
    # pymc_usb — Heltec TCP panel endpoints (basic-auth gated)
    # =========================================================================
    #
    # Three routes are added by scripts/install.sh:
    #   GET  /heltec                       → static HTML panel (heltec_panel.html)
    #   GET  /api/get_tcp_heltec_config    → returns current host/port/token state
    #   POST /api/update_tcp_heltec_config → writes config.yaml + live-pushes to driver
    #
    # All three require HTTP Basic auth with admin password from
    # config.yaml -> repeater.security.admin_password. We deliberately don't
    # tie this to the JWT flow because the panel is a single-page form
    # opened from a browser, and Basic auth gives the user a native prompt
    # without needing the SPA's login machinery.

    def _heltec_basic_auth(self):
        """Raise 401 if Authorization header doesn't match admin password."""
        import base64
        auth = cherrypy.request.headers.get("Authorization", "")
        expected_pw = (
            self.config.get("repeater", {})
            .get("security", {})
            .get("admin_password", "")
        )
        if not auth.startswith("Basic ") or not expected_pw:
            cherrypy.response.headers["WWW-Authenticate"] = 'Basic realm="Heltec TCP panel"'
            raise cherrypy.HTTPError(401, "Authentication required")
        try:
            user, _, password = base64.b64decode(auth[6:]).decode("utf-8").partition(":")
        except Exception:
            cherrypy.response.headers["WWW-Authenticate"] = 'Basic realm="Heltec TCP panel"'
            raise cherrypy.HTTPError(401, "Bad credentials")
        # User name is ignored — we only check the password against admin_password.
        if password != expected_pw:
            cherrypy.response.headers["WWW-Authenticate"] = 'Basic realm="Heltec TCP panel"'
            raise cherrypy.HTTPError(401, "Bad credentials")

    @cherrypy.expose
    def heltec(self):
        """Serve the static Heltec TCP configuration panel."""
        self._heltec_basic_auth()
        import os
        html_path = os.path.join(os.path.dirname(__file__), "html", "heltec_panel.html")
        if not os.path.exists(html_path):
            raise cherrypy.HTTPError(500, "heltec_panel.html missing — re-run install.sh")
        cherrypy.response.headers["Content-Type"] = "text/html; charset=utf-8"
        with open(html_path, "rb") as f:
            return f.read()

    @cherrypy.expose
    @cherrypy.tools.json_out()
    def get_tcp_heltec_config(self):
        """Read-only view of the current tcp_heltec block."""
        self._heltec_basic_auth()
        tcp = self.config.get("tcp_heltec", {}) or {}
        return {
            "radio_type": self.config.get("radio_type", ""),
            "host": tcp.get("host", ""),
            "port": int(tcp.get("port", 5055)),
            "has_token": bool(tcp.get("token", "")),
        }

    @cherrypy.expose
    @cherrypy.tools.json_out()
    @cherrypy.tools.json_in()
    def update_tcp_heltec_config(self):
        """Persist host/port/token to config.yaml and live-push to the driver."""
        self._heltec_basic_auth()
        try:
            self._require_post()
            data = cherrypy.request.json or {}
            host = (data.get("host") or "").strip()
            try:
                port = int(data.get("port", 5055))
            except (TypeError, ValueError):
                return {"success": False, "error": "port must be an integer"}
            if not host:
                return {"success": False, "error": "host is required"}
            if not (1 <= port <= 65535):
                return {"success": False, "error": "port out of range"}

            import yaml
            with open(self._config_path, "r") as f:
                cfg = yaml.safe_load(f) or {}
            cfg.setdefault("tcp_heltec", {})
            cfg["tcp_heltec"]["host"] = host
            cfg["tcp_heltec"]["port"] = port

            # Token is optional. Only overwrite if the client sent the field
            # explicitly (empty string from "leave unchanged" UI doesn't count).
            new_token = None
            if "token" in data:
                new_token = data.get("token") or ""
                cfg["tcp_heltec"]["token"] = new_token

            # Force radio_type to tcp_heltec — applying these settings only
            # makes sense for that mode.
            cfg["radio_type"] = "tcp_heltec"

            with open(self._config_path, "w") as f:
                yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)

            # Live push to running driver (best-effort — daemon may not yet
            # have the radio attached if this is the first call after boot).
            applied_live = False
            radio = None
            if self.daemon_instance is not None:
                radio = getattr(self.daemon_instance, "radio", None)
            if radio is not None and hasattr(radio, "set_tcp_target"):
                kwargs = {"host": host, "port": port}
                if new_token is not None:
                    kwargs["token"] = new_token
                applied_live = bool(radio.set_tcp_target(**kwargs))

            return {
                "success": True,
                "message": (
                    "Saved to config.yaml and pushed live to the running radio."
                    if applied_live else
                    "Saved to config.yaml. Restart the service if the driver "
                    "isn't picking up the change automatically."
                ),
                "config": {"host": host, "port": port, "has_token": bool(cfg["tcp_heltec"].get("token"))},
            }
        except cherrypy.HTTPError:
            raise
        except Exception as e:
            logger.error(f"update_tcp_heltec_config failed: {e}", exc_info=True)
            return {"success": False, "error": str(e)}
