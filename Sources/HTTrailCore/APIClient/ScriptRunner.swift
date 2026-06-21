import Foundation
import JavaScriptCore

/// Result of running a pre-request or test script.
public struct ScriptResult: Sendable {
    public var environment: [String: String]
    public var request: APIRequest
    public var consoleLog: [String]
    public var tests: [TestResult]
    public var error: String?

    public struct TestResult: Sendable {
        public var name: String
        public var passed: Bool
        public var message: String?
    }
}

/// Runs Hoppscotch/Postman-style pre-request and test scripts in a sandboxed
/// JavaScriptCore context, exposing a `pm`-compatible API. No HTML/web stack —
/// JavaScriptCore is a first-class Apple framework.
public final class ScriptRunner: @unchecked Sendable {
    public init() {}

    public func runPreRequest(_ script: String, request: APIRequest,
                              environment: [String: String]) -> ScriptResult {
        run(script, request: request, response: nil, environment: environment)
    }

    public func runTests(_ script: String, request: APIRequest, response: APIResponse,
                         environment: [String: String]) -> ScriptResult {
        run(script, request: request, response: response, environment: environment)
    }

    private func run(_ script: String, request: APIRequest, response: APIResponse?,
                     environment: [String: String]) -> ScriptResult {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let context = JSContext() else {
            return ScriptResult(environment: environment, request: request, consoleLog: [], tests: [])
        }

        var env = environment
        var mutableRequest = request
        var logs: [String] = []
        var tests: [ScriptResult.TestResult] = []
        var scriptError: String?

        context.exceptionHandler = { _, exception in
            scriptError = exception?.toString() ?? "Unknown script error"
        }

        // console.log
        let log: @convention(block) (JSValue) -> Void = { value in
            logs.append(value.toString() ?? "")
        }
        context.setObject(log, forKeyedSubscript: "__log" as NSString)

        // Environment get/set bridges.
        let envGet: @convention(block) (String) -> String? = { key in env[key] }
        let envSet: @convention(block) (String, String) -> Void = { key, value in env[key] = value }
        let envUnset: @convention(block) (String) -> Void = { key in env.removeValue(forKey: key) }
        context.setObject(envGet, forKeyedSubscript: "__envGet" as NSString)
        context.setObject(envSet, forKeyedSubscript: "__envSet" as NSString)
        context.setObject(envUnset, forKeyedSubscript: "__envUnset" as NSString)

        // Request header set (pre-request mutation).
        let headerSet: @convention(block) (String, String) -> Void = { name, value in
            mutableRequest.headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            mutableRequest.headers.append(KeyValueItem(name: name, value: value))
        }
        context.setObject(headerSet, forKeyedSubscript: "__headerSet" as NSString)

        // Test reporting bridge.
        let report: @convention(block) (String, Bool, String?) -> Void = { name, passed, message in
            tests.append(.init(name: name, passed: passed, message: message))
        }
        context.setObject(report, forKeyedSubscript: "__report" as NSString)

        // Response object for test scripts.
        if let response {
            context.setObject(response.statusCode, forKeyedSubscript: "__resCode" as NSString)
            context.setObject(response.bodyString, forKeyedSubscript: "__resText" as NSString)
            let headerObj = response.headers.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
            context.setObject(headerObj, forKeyedSubscript: "__resHeaders" as NSString)
        }
        context.setObject(mutableRequest.method, forKeyedSubscript: "__reqMethod" as NSString)
        context.setObject(mutableRequest.url, forKeyedSubscript: "__reqUrl" as NSString)

        context.evaluateScript(Self.preamble)
        context.evaluateScript(script)

        return ScriptResult(environment: env, request: mutableRequest, consoleLog: logs,
                            tests: tests, error: scriptError)
    }

    /// The `pm` shim implemented on top of the native bridges above.
    private static let preamble = """
    var console = { log: function() {
        __log(Array.prototype.slice.call(arguments).map(function(a) {
            return (typeof a === 'object') ? JSON.stringify(a) : String(a);
        }).join(' '));
    } };
    function expect(actual) {
        return {
            to: {
                equal: function(expected) {
                    if (actual !== expected) throw new Error('Expected ' + JSON.stringify(actual) + ' to equal ' + JSON.stringify(expected));
                },
                eql: function(expected) {
                    if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Expected ' + JSON.stringify(actual) + ' to eql ' + JSON.stringify(expected));
                },
                be: {
                    ok: function() { if (!actual) throw new Error('Expected value to be ok'); },
                    a: function(t) { if (typeof actual !== t) throw new Error('Expected type ' + t); }
                },
                include: function(sub) {
                    if (String(actual).indexOf(sub) < 0) throw new Error('Expected to include ' + sub);
                },
                have: {
                    status: function(code) {
                        if (pm.response.code !== code) throw new Error('Expected status ' + code + ' got ' + pm.response.code);
                    }
                }
            }
        };
    }
    var pm = {
        environment: { get: __envGet, set: __envSet, unset: __envUnset },
        variables: { get: __envGet, set: __envSet },
        request: {
            method: __reqMethod, url: __reqUrl,
            headers: { add: function(h) { __headerSet(h.key, h.value); }, set: __headerSet }
        },
        response: {
            code: (typeof __resCode !== 'undefined') ? __resCode : 0,
            status: (typeof __resCode !== 'undefined') ? __resCode : 0,
            text: function() { return (typeof __resText !== 'undefined') ? __resText : ''; },
            json: function() { return JSON.parse((typeof __resText !== 'undefined') ? __resText : 'null'); },
            headers: { get: function(k) { return (__resHeaders || {})[k]; } }
        },
        expect: expect,
        test: function(name, fn) {
            try { fn(); __report(name, true, null); }
            catch (e) { __report(name, false, e.message); }
        }
    };
    """
}
