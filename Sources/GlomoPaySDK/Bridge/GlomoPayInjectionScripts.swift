import Foundation

/// JavaScript injected into WKWebView. Payment detection remains exclusively
/// on the window.postMessage channel, matching the Flutter/Kotlin SDKs.
public enum GlomoPayInjectionScripts {
    public static let main = build(bridgeName: "GlomoPayBridge")
    public static let flow = build(bridgeName: "GlomoPayFlowBridge")

    public static func bootstrap(devMode: Bool) -> String {
        "window.__glomoDevMode__ = \(devMode ? "true" : "false");"
    }

    public static let credentialedRequestsFix = """
    (function() {
      if (window.__glomoIOSCredentialedRequestsFix__) return;
      window.__glomoIOSCredentialedRequestsFix__ = true;
      var originalFetch = window.fetch;
      window.fetch = function() {
        var args = arguments;
        if (args[1] && typeof args[1] === 'object') {
          args[1].credentials = args[1].credentials || 'include';
        } else if (typeof args[1] === 'undefined') {
          args[1] = { credentials: 'include' };
        }
        return originalFetch.apply(this, args);
      };
      var originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        try { this.withCredentials = true; } catch (e) {}
        return originalOpen.apply(this, arguments);
      };
    })();
    """

    /// Prevents iOS WKWebView from zooming the page when an editable field
    /// smaller than 16px receives focus.
    public static let iosInputZoomFix = """
    (function() {
      if (window.__glomoIOSInputZoomFixApplied__) return;
      window.__glomoIOSInputZoomFixApplied__ = true;

      var css = [
        'input, textarea, select {',
        '  font-size: 16px !important;',
        '  -webkit-text-size-adjust: 100%;',
        '}',
        'input:focus, textarea:focus, select:focus {',
        '  touch-action: manipulation;',
        '}'
      ].join(' ');

      function install() {
        if (document.getElementById('__glomo_ios_input_zoom_fix__')) return;
        var style = document.createElement('style');
        style.id = '__glomo_ios_input_zoom_fix__';
        style.type = 'text/css';
        style.appendChild(document.createTextNode(css));
        (document.head || document.documentElement).appendChild(style);
      }

      install();
      document.addEventListener('DOMContentLoaded', install, { once: true });
    })();
    """

    /// Keeps checkout content at a 1:1 viewport scale on iOS.
    public static let iosViewportFitFix = """
    (function() {
      if (window.__glomoIOSViewportFitFixApplied__) return;
      window.__glomoIOSViewportFitFixApplied__ = true;

      function ensureViewport() {
        var head = document.head || document.getElementsByTagName('head')[0];
        if (!head) return;
        var meta = document.querySelector('meta[name="viewport"]');
        if (!meta) {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          head.appendChild(meta);
        }
        meta.setAttribute(
          'content',
          'width=device-width, initial-scale=1, maximum-scale=1, minimum-scale=1, user-scalable=no, viewport-fit=cover'
        );
      }

      function normalizeZoom() {
        try { document.documentElement.style.zoom = '1'; } catch (e) {}
        try { if (document.body) document.body.style.zoom = '1'; } catch (e) {}
      }

      function apply() {
        ensureViewport();
        normalizeZoom();
      }

      apply();
      document.addEventListener('DOMContentLoaded', apply, { once: true });
      window.addEventListener('load', apply);
      window.addEventListener('orientationchange', apply, true);
    })();
    """

    private static func build(bridgeName: String) -> String {
        """
        (function() {
          var flag = '__glomo_\(bridgeName)_Injected__';
          if (window[flag]) return;
          window[flag] = true;
          var DEV = function() { return !!window.__glomoDevMode__; };
          var bridge = function(message) {
            if (window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.\(bridgeName)) {
              window.webkit.messageHandlers.\(bridgeName).postMessage(message);
            }
          };
          function send(level, message) {
            if (DEV() || level === 'error') {
              bridge(JSON.stringify({type: 'console', level: level, message: String(message)}));
            }
          }
          var originalLog = console.log;
          var originalWarn = console.warn;
          var originalError = console.error;
          console.log = function(message) { originalLog(message); send('log', message); };
          console.warn = function(message) { originalWarn(message); send('warn', message); };
          console.error = function(message) { originalError(message); send('error', message); };

          window.open = function(url) {
            if (url) bridge(JSON.stringify({type: 'window.open', url: String(url)}));
            return {
              close: function() { bridge(JSON.stringify({type: 'window.close'})); },
              focus: function() {},
              blur: function() {},
              postMessage: function() {}
            };
          };
          var originalClose = window.close;
          window.close = function() {
            bridge(JSON.stringify({type: 'window.close'}));
            try { originalClose(); } catch (e) {}
          };

          (function() {
            if (!window._glomoFormSubmitOverride_) {
              window._glomoFormSubmitOverride_ = true;
              var originalSubmit = HTMLFormElement.prototype.submit;
              HTMLFormElement.prototype.submit = function() {
                if (this.target === '_blank') this.target = '_self';
                return originalSubmit.call(this);
              };
            }
          })();

          window.addEventListener('message', function(event) {
            if (event.data) bridge(JSON.stringify({type: 'message', data: event.data}));
          });
          window.addEventListener('error', function(event) {
            send('error', 'Uncaught: ' + event.message);
          });
          window.addEventListener('unhandledrejection', function(event) {
            send('error', 'Unhandled Rejection: ' + event.reason);
          });
          document.addEventListener('click', function(event) {
            var target = event.target;
            if (target && target.tagName === 'INPUT' && target.type === 'file') {
              bridge(JSON.stringify({type: 'file.input', accept: target.accept || '', inputId: target.id || '', inputName: target.name || ''}));
            }
          }, true);
        })();
        """
    }
}
