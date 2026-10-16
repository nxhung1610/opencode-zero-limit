import Foundation

/// The JavaScript half of the sandbox: Node-style globals built on top of the
/// host APIs installed by `ProxyScriptRuntime`. Evaluated once per script run,
/// inside the fresh context, before the user script itself.
///
/// Deliberately absent: files, processes, modules (`require`/`import`), any
/// network beyond `http.get`/`http.post`, and real asynchronous I/O. The
/// runtime pump makes `await`, promises, and timers work even though every
/// host call underneath is synchronous.
enum ProxyScriptShim {
    static let source: String = #"""
    // The shim installs itself on the global object; the runtime reads back
    // the `__relaydock*` state (promise settlement, timers, cache snapshot)
    // between microtask drains.
    var __startedAt = Date.now();

      // ---- internal run state ------------------------------------------

      var __relaydockSettled = false;
      var __relaydockValue = undefined;
      var __relaydockError = undefined;
      var __relaydockPromise = undefined;

      function __relaydockFail(error) {
        if (!__relaydockSettled) {
          __relaydockSettled = true;
          __relaydockError = error;
        }
      }

      function __relaydockDescribeError(error) {
        try {
          if (error && typeof error === "object") {
            var name = typeof error.name === "string" ? error.name : "";
            var message = typeof error.message === "string" ? error.message : "";
            if (name && name !== "Error" && message) return name + ": " + message;
            if (message) return message;
          }
          return String(error);
        } catch (ignored) {
          return "unknown error";
        }
      }

      function __relaydockSnapshot() {
        try {
          var json = JSON.stringify(cache);
          if (typeof json !== "string" || json.length > 65536) return null;
          return json;
        } catch (ignored) {
          return null;
        }
      }

      // ---- byte / text helpers ------------------------------------------

      function utf8Bytes(text) {
        var out = [];
        for (var i = 0; i < text.length; i++) {
          var code = text.codePointAt(i);
          if (code > 0xffff) i++;
          if (code < 0x80) {
            out.push(code);
          } else if (code < 0x800) {
            out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
          } else if (code < 0x10000) {
            out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
          } else {
            out.push(
              0xf0 | (code >> 18),
              0x80 | ((code >> 12) & 63),
              0x80 | ((code >> 6) & 63),
              0x80 | (code & 63)
            );
          }
        }
        return out;
      }

      function utf8Decode(bytes) {
        var out = "";
        var i = 0;
        while (i < bytes.length) {
          var b = bytes[i++];
          if (b < 0x80) {
            out += String.fromCharCode(b);
          } else if (b < 0xe0) {
            out += String.fromCharCode(((b & 31) << 6) | (bytes[i++] & 63));
          } else if (b < 0xf0) {
            out += String.fromCharCode(
              ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63)
            );
          } else {
            var point =
              ((b & 7) << 18) |
              ((bytes[i++] & 63) << 12) |
              ((bytes[i++] & 63) << 6) |
              (bytes[i++] & 63);
            point -= 0x10000;
            out += String.fromCharCode(0xd800 + (point >> 10), 0xdc00 + (point & 1023));
          }
        }
        return out;
      }

      function bytesToBinaryString(bytes) {
        var out = "";
        for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i] & 0xff);
        return out;
      }

      function binaryStringToBytes(text) {
        var out = [];
        for (var i = 0; i < text.length; i++) out.push(text.charCodeAt(i) & 0xff);
        return out;
      }

      function bytesToHex(bytes) {
        var out = "";
        for (var i = 0; i < bytes.length; i++) out += ("0" + bytes[i].toString(16)).slice(-2);
        return out;
      }

      function hexToBytes(hex) {
        var text = String(hex);
        if (text.length % 2 !== 0 || /[^0-9a-fA-F]/.test(text)) {
          throw new Error("invalid hex string");
        }
        var out = [];
        for (var i = 0; i < text.length; i += 2) out.push(parseInt(text.slice(i, i + 2), 16));
        return out;
      }

      function bytesToBase64(bytes) {
        return btoa(bytesToBinaryString(bytes));
      }

      function base64ToBytes(encoded) {
        return binaryStringToBytes(atob(String(encoded)));
      }

      function toByteArray(value) {
        if (value instanceof Uint8Array) return Array.prototype.slice.call(value);
        if (Array.isArray(value)) {
          return value.map(function (entry) {
            return entry & 0xff;
          });
        }
        if (value instanceof BufferValue) return value._bytes.slice();
        throw new TypeError("expected a byte array");
      }

      // ---- TextEncoder / TextDecoder ------------------------------------

      function TextEncoder() {}

      TextEncoder.prototype.encode = function (input) {
        return new Uint8Array(utf8Bytes(input === undefined ? "" : String(input)));
      };

      function TextDecoder(label) {
        var name = label === undefined ? "utf-8" : String(label).toLowerCase();
        if (name !== "utf-8" && name !== "utf8") {
          throw new RangeError("TextDecoder: only utf-8 is supported");
        }
      }

      TextDecoder.prototype.decode = function (bytes) {
        return utf8Decode(bytes === undefined ? [] : toByteArray(bytes));
      };

      // ---- Buffer (subset of the Node API) ------------------------------

      function BufferValue(bytes) {
        this._bytes = bytes;
      }

      Object.defineProperty(BufferValue.prototype, "length", {
        get: function () {
          return this._bytes.length;
        },
      });

      BufferValue.prototype.toString = function (encoding) {
        var name = (encoding === undefined ? "utf8" : String(encoding)).toLowerCase();
        if (name === "utf8" || name === "utf-8") return utf8Decode(this._bytes);
        if (name === "hex") return bytesToHex(this._bytes);
        if (name === "base64") return bytesToBase64(this._bytes);
        throw new Error("Buffer.toString: unsupported encoding " + encoding);
      };

      var Buffer = {
        from: function (input, encoding) {
          if (typeof input === "string") {
            var name = (encoding === undefined ? "utf8" : String(encoding)).toLowerCase();
            if (name === "utf8" || name === "utf-8") return new BufferValue(utf8Bytes(input));
            if (name === "hex") return new BufferValue(hexToBytes(input));
            if (name === "base64") return new BufferValue(base64ToBytes(input));
            throw new Error("Buffer.from: unsupported encoding " + encoding);
          }
          if (input instanceof BufferValue) return new BufferValue(input._bytes.slice());
          return new BufferValue(toByteArray(input));
        },
        alloc: function (size, fill) {
          var length = size === undefined ? 0 : size | 0;
          if (length < 0) throw new RangeError("Buffer.alloc: size must be >= 0");
          var byte = typeof fill === "number" ? fill & 0xff : 0;
          var bytes = [];
          for (var i = 0; i < length; i++) bytes.push(byte);
          return new BufferValue(bytes);
        },
        byteLength: function (value, encoding) {
          return Buffer.from(value, encoding)._bytes.length;
        },
        concat: function (list) {
          var bytes = [];
          for (var i = 0; i < list.length; i++) {
            bytes = bytes.concat(Buffer.from(list[i])._bytes);
          }
          return new BufferValue(bytes);
        },
        isBuffer: function (value) {
          return value instanceof BufferValue;
        },
      };

      // ---- URL / URLSearchParams ----------------------------------------

      function formEncode(text) {
        return encodeURIComponent(text)
          .replace(/[!'()*]/g, function (character) {
            return "%" + character.charCodeAt(0).toString(16).toUpperCase();
          })
          .replace(/%20/g, "+");
      }

      function formDecode(text) {
        try {
          return decodeURIComponent(text.replace(/\+/g, " "));
        } catch (ignored) {
          return text;
        }
      }

      function URLSearchParams(init) {
        this._pairs = [];
        var self = this;
        if (typeof init === "string") {
          var query = init.charAt(0) === "?" ? init.slice(1) : init;
          if (query.length) {
            query.split("&").forEach(function (part) {
              if (!part.length) return;
              var equals = part.indexOf("=");
              var name = equals < 0 ? part : part.slice(0, equals);
              var value = equals < 0 ? "" : part.slice(equals + 1);
              self._pairs.push([formDecode(name), formDecode(value)]);
            });
          }
        } else if (init && typeof init === "object") {
          Object.keys(init).forEach(function (key) {
            self._pairs.push([String(key), String(init[key])]);
          });
        }
      }

      URLSearchParams.prototype.append = function (name, value) {
        this._pairs.push([String(name), String(value)]);
      };

      URLSearchParams.prototype.delete = function (name) {
        var key = String(name);
        this._pairs = this._pairs.filter(function (pair) {
          return pair[0] !== key;
        });
      };

      URLSearchParams.prototype.get = function (name) {
        var key = String(name);
        for (var i = 0; i < this._pairs.length; i++) {
          if (this._pairs[i][0] === key) return this._pairs[i][1];
        }
        return null;
      };

      URLSearchParams.prototype.getAll = function (name) {
        var key = String(name);
        return this._pairs
          .filter(function (pair) {
            return pair[0] === key;
          })
          .map(function (pair) {
            return pair[1];
          });
      };

      URLSearchParams.prototype.has = function (name) {
        var key = String(name);
        return this._pairs.some(function (pair) {
          return pair[0] === key;
        });
      };

      URLSearchParams.prototype.set = function (name, value) {
        var key = String(name);
        var text = String(value);
        var replaced = false;
        var next = [];
        this._pairs.forEach(function (pair) {
          if (pair[0] !== key) {
            next.push(pair);
          } else if (!replaced) {
            next.push([key, text]);
            replaced = true;
          }
        });
        if (!replaced) next.push([key, text]);
        this._pairs = next;
      };

      URLSearchParams.prototype.toString = function () {
        return this._pairs
          .map(function (pair) {
            return formEncode(pair[0]) + "=" + formEncode(pair[1]);
          })
          .join("&");
      };

      Object.defineProperty(URLSearchParams.prototype, "size", {
        get: function () {
          return this._pairs.length;
        },
      });

      function safeDecodeURIComponent(text) {
        try {
          return decodeURIComponent(text);
        } catch (ignored) {
          return text;
        }
      }

      function URL(input, base) {
        if (base !== undefined) {
          throw new Error("URL: relative URLs with a base are not supported");
        }
        var source = String(input);
        var match = /^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\/(?:([^@\/?#]*)@)?(\[[0-9a-fA-F:]+\]|[^:\/?#]*)(?::(\d*))?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(source);
        if (!match) throw new TypeError("Invalid URL: " + source);
        this.protocol = match[1].toLowerCase() + ":";
        var userinfo = match[2] || "";
        var colon = userinfo.indexOf(":");
        this.username = colon < 0 ? safeDecodeURIComponent(userinfo) : safeDecodeURIComponent(userinfo.slice(0, colon));
        this.password = colon < 0 ? "" : safeDecodeURIComponent(userinfo.slice(colon + 1));
        this.hostname = match[3].toLowerCase();
        this.port = match[4] || "";
        this.pathname = match[5] || "/";
        this.searchParams = new URLSearchParams(match[6] || "");
        this.hash = match[7] || "";
      }

      Object.defineProperty(URL.prototype, "search", {
        get: function () {
          var rendered = this.searchParams.toString();
          return rendered.length ? "?" + rendered : "";
        },
      });

      Object.defineProperty(URL.prototype, "host", {
        get: function () {
          return this.port ? this.hostname + ":" + this.port : this.hostname;
        },
      });

      Object.defineProperty(URL.prototype, "origin", {
        get: function () {
          return this.protocol + "//" + this.host;
        },
      });

      URL.prototype.toString = function () {
        var userinfo = this.username
          ? this.username + (this.password ? ":" + this.password : "") + "@"
          : "";
        return (
          this.protocol + "//" + userinfo + this.host + this.pathname + this.search + this.hash
        );
      };

      URL.prototype.toJSON = function () {
        return this.toString();
      };

      // ---- crypto (host-backed hashing) ---------------------------------

      var HASH_ALGORITHMS = {
        sha256: "sha256",
        "sha-256": "sha256",
        sha384: "sha384",
        "sha-384": "sha384",
        sha512: "sha512",
        "sha-512": "sha512",
      };

      function normalizedAlgorithm(name) {
        var algorithm = HASH_ALGORITHMS[String(name).toLowerCase()];
        if (!algorithm) throw new Error("crypto: unsupported algorithm " + name);
        return algorithm;
      }

      function stringifyChunk(data) {
        if (typeof data === "string") return data;
        if (data instanceof BufferValue) return utf8Decode(data._bytes);
        if (data instanceof Uint8Array || Array.isArray(data)) return utf8Decode(toByteArray(data));
        return String(data);
      }

      function digestWithEncoding(hex, encoding) {
        if (encoding === undefined || encoding === null || encoding === "hex") return hex;
        if (encoding === "base64") return bytesToBase64(hexToBytes(hex));
        throw new Error("crypto: unsupported digest encoding " + encoding);
      }

      function createHash(algorithm) {
        var name = normalizedAlgorithm(algorithm);
        var chunks = [];
        return {
          update: function (data) {
            chunks.push(stringifyChunk(data));
            return this;
          },
          digest: function (encoding) {
            return digestWithEncoding(__relaydockSHA(name, chunks.join("")), encoding);
          },
        };
      }

      function createHmac(algorithm, key) {
        var name = normalizedAlgorithm(algorithm);
        var secret = stringifyChunk(key);
        var chunks = [];
        return {
          update: function (data) {
            chunks.push(stringifyChunk(data));
            return this;
          },
          digest: function (encoding) {
            return digestWithEncoding(__relaydockHMAC(name, secret, chunks.join("")), encoding);
          },
        };
      }

      var crypto = {
        createHash: createHash,
        createHmac: createHmac,
        randomUUID: function () {
          return __relaydockUUID();
        },
        randomBytes: function (size) {
          var count = size === undefined ? 0 : size | 0;
          if (count < 0) throw new RangeError("crypto.randomBytes: size must be >= 0");
          return Buffer.from(__relaydockRandomHex(count), "hex");
        },
      };

      // ---- timers --------------------------------------------------------

      var __timers = [];
      var __nextTimerID = 1;

      function scheduleTimer(callback, delay, repeating) {
        if (typeof callback !== "function") {
          throw new TypeError("timer callback must be a function");
        }
        var milliseconds = typeof delay === "number" && delay > 0 ? delay : 0;
        var timer = {
          id: __nextTimerID++,
          callback: callback,
          due: Date.now() + milliseconds,
          every: repeating ? Math.max(milliseconds, 1) : 0,
        };
        __timers.push(timer);
        return timer.id;
      }

      function cancelTimer(id) {
        for (var i = 0; i < __timers.length; i++) {
          if (__timers[i].id === id) {
            __timers.splice(i, 1);
            return;
          }
        }
      }

      function __relaydockRunDueTimers(now) {
        var ran = 0;
        var dueNow = __timers.filter(function (timer) {
          return timer.due <= now;
        });
        for (var i = 0; i < dueNow.length; i++) {
          var timer = dueNow[i];
          var index = __timers.indexOf(timer);
          if (index < 0) continue;
          if (timer.every) {
            timer.due = now + timer.every;
          } else {
            __timers.splice(index, 1);
          }
          try {
            timer.callback();
            ran += 1;
          } catch (error) {
            __relaydockFail(error);
            return ran;
          }
        }
        return ran;
      }

      function __relaydockNextTimerDelay(now) {
        var smallest = Infinity;
        for (var i = 0; i < __timers.length; i++) {
          var delay = __timers[i].due - now;
          if (delay < smallest) smallest = delay;
        }
        return smallest === Infinity ? -1 : smallest;
      }

      // ---- fetch (promise-flavoured http.get / http.post) ----------------

      function fetch(url, options) {
        options = options || {};
        var method = String(options.method || "GET").toUpperCase();
        var headers = options.headers === undefined ? null : options.headers;
        return new Promise(function (resolve, reject) {
          var body;
          try {
            if (method === "GET" || method === "HEAD") {
              body = http.get(String(url), headers);
            } else if (method === "POST") {
              var payload = options.body === undefined || options.body === null ? "" : String(options.body);
              body = http.post(String(url), payload, headers);
            } else {
              throw new Error("fetch: method " + method + " is not supported");
            }
          } catch (error) {
            reject(error);
            return;
          }
          resolve({
            ok: true,
            status: 200,
            url: String(url),
            headers: {
              get: function () {
                return null;
              },
              has: function () {
                return false;
              },
            },
            text: function () {
              return Promise.resolve(body);
            },
            json: function () {
              return Promise.resolve().then(function () {
                return JSON.parse(body);
              });
            },
          });
        });
      }

      // ---- misc ----------------------------------------------------------

      function structuredClone(value) {
        return JSON.parse(JSON.stringify(value));
      }

      var performance = {
        now: function () {
          return Date.now() - __startedAt;
        },
      };

      // ---- install globals -----------------------------------------------

      globalThis.TextEncoder = TextEncoder;
      globalThis.TextDecoder = TextDecoder;
      globalThis.Buffer = Buffer;
      globalThis.URL = URL;
      globalThis.URLSearchParams = URLSearchParams;
      globalThis.crypto = crypto;
      globalThis.structuredClone = structuredClone;
      globalThis.performance = performance;
      globalThis.fetch = fetch;
      globalThis.setTimeout = function (callback, delay) {
        return scheduleTimer(callback, delay, false);
      };
      globalThis.setInterval = function (callback, delay) {
        return scheduleTimer(callback, delay, true);
      };
      globalThis.clearTimeout = cancelTimer;
      globalThis.clearInterval = cancelTimer;
      globalThis.queueMicrotask = function (callback) {
        Promise.resolve().then(callback);
      };
    """#
}
