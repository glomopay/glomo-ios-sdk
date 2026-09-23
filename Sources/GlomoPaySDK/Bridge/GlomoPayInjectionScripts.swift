import Foundation

/// JavaScript injected into WKWebView. Payment detection remains exclusively
/// on the window.postMessage channel, matching the Flutter/Kotlin SDKs.
public enum GlomoPayInjectionScripts {
    public static let main = build(bridgeName: "GlomoPayBridge", emitsBridgeReady: true)

    /// The flow script is the base bridge plus the `window.opener` stub, and it is injected at
    /// `.atDocumentStart` so the stub exists before the bank page's own scripts run: pages
    /// opened through `window.open` call `opener.postMessage()` during load.
    public static let flow = build(bridgeName: "GlomoPayFlowBridge", emitsBridgeReady: false)
        + openerStub(bridgeName: "GlomoPayFlowBridge")

    /// Carries payment results from bank pages that report through `window.opener`.
    /// Without it those pages produce no bridge message at all: the payment completes at the
    /// bank and the SDK never hears about it.
    ///
    /// It routes through `window.__glomoBridge__`, the sender `build()` publishes, and falls
    /// back to the message handler directly. This path must never be silently suppressed, so
    /// the fallback is deliberate rather than a convenience.
    static func openerStub(bridgeName: String) -> String {
        """
        (function() {
          if (window.__glomoOpenerStubInjected__) return;
          window.__glomoOpenerStubInjected__ = true;
          try {
            if (!window.opener) {
              var flowBridge = function(message) {
                if (window.__glomoBridge__) return window.__glomoBridge__(message);
                try {
                  if (window.webkit && window.webkit.messageHandlers &&
                      window.webkit.messageHandlers.\(bridgeName)) {
                    window.webkit.messageHandlers.\(bridgeName).postMessage(message);
                  }
                } catch (e) {}
              };
              window.opener = {
                postMessage: function(message) {
                  flowBridge(JSON.stringify({type: 'message', data: message}));
                },
                close: function() {},
                closed: false
              };
            }
          } catch (e) {}
        })();
        """
    }

    /// Listens for the hosted carousel page's availability message.
    ///
    /// Flutter monkey-patches `window.postMessage` here, with a comment that same-frame
    /// message events are not reliably delivered to `addEventListener` on Android WebView.
    /// That constraint does not apply to WKWebView, so this uses the listener rather than
    /// porting the patch as a cargo cult.
    static func carousel(bridgeName: String = "GlomoCarouselBridge") -> String {
        """
        (function() {
          if (window.__glomoCarouselListenerReady__) return;
          window.__glomoCarouselListenerReady__ = true;
          var send = function(data) {
            try {
              var parsed = typeof data === 'string' ? JSON.parse(data) : data;
              if (!parsed) return;
              if (parsed.event !== 'lrs.has_education_steps') return;
              if (typeof parsed.hasContent !== 'boolean') return;
              window.__glomoCarouselStateSent__ = true;
              if (window.webkit && window.webkit.messageHandlers &&
                  window.webkit.messageHandlers.\(bridgeName)) {
                window.webkit.messageHandlers.\(bridgeName).postMessage(
                  JSON.stringify({event: parsed.event, hasContent: parsed.hasContent})
                );
              }
            } catch (e) {}
          };
          window.addEventListener('message', function(event) {
            if (event.data) send(event.data);
          });
        })();
        """
    }

    /// Runs 3 seconds after the page finishes, and only if the page never posted.
    /// Some carousel pages render content without announcing it.
    static func carouselFallback(bridgeName: String = "GlomoCarouselBridge") -> String {
        """
        (function() {
          if (window.__glomoCarouselPollScheduled__) return;
          window.__glomoCarouselPollScheduled__ = true;
          setTimeout(function() {
            if (window.__glomoCarouselStateSent__) return;
            try {
              var body = document.body;
              var text = body && body.innerText ? body.innerText.trim() : '';
              var nodes = body ? body.querySelectorAll('*').length : 0;
              var hasContent = text.length > 100 || nodes > 10;
              if (window.webkit && window.webkit.messageHandlers &&
                  window.webkit.messageHandlers.\(bridgeName)) {
                window.webkit.messageHandlers.\(bridgeName).postMessage(
                  JSON.stringify({event: 'lrs.has_education_steps', hasContent: hasContent})
                );
              }
            } catch (e) {}
          }, 3000);
        })();
        """
    }

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

    private static func build(bridgeName: String, emitsBridgeReady: Bool) -> String {
        let readySignal = emitsBridgeReady
            ? """
              // The main checkout's final open-funnel step. Flow WebViews must not emit this.
              bridge(JSON.stringify({type: 'bridge.ready'}));
              """
            : ""
        return """
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
          // Published so the opener stub can route through the same sender instead of
          // reaching for the message handler and falling through on every call.
          if (!window.__glomoBridge__) window.__glomoBridge__ = bridge;
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
          \(readySignal)
        })();
        """
    }
}
