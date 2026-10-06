import CoreLocation
import Foundation
import WebKit

/// Bridges `navigator.geolocation` to CoreLocation, mirroring `UBLocation`.
///
/// The injected JavaScript (a copy of `Uebersicht/geolocation.js`) replaces
/// `getCurrentPosition` / `watchPosition` with calls that post
/// `{type, callbackId}` to the `geolocation` message handler; responses come back as
/// `__UBCallbacks__.call(callbackId, <json>)`.
final class GeolocationBridge: NSObject, WKScriptMessageHandler, CLLocationManagerDelegate {
    private struct Pending {
        let webView: WKWebView?
        let callbackId: Int
    }

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var pending: [Int: Pending] = [:]
    private var currentPosition: String?
    private var started = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let callbackId = (body["callbackId"] as? NSNumber)?.intValue
        else { return }

        switch type {
        case "registerCallback":
            if !started {
                manager.startUpdatingLocation()
                started = true
            }
            pending[callbackId] = Pending(webView: message.webView, callbackId: callbackId)
            if let currentPosition {
                respond(Pending(webView: message.webView, callbackId: callbackId), currentPosition)
            }
        case "removeCallback":
            pending.removeValue(forKey: callbackId)
            if pending.isEmpty && started {
                manager.stopUpdatingLocation()
                currentPosition = nil
                started = false
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            let place = placemarks?.first
            let json = Self.positionJSON(location: location, place: place)
            DispatchQueue.main.async {
                guard let self else { return }
                self.currentPosition = json
                for pending in self.pending.values {
                    self.respond(pending, json)
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("geolocation failed: %@", error.localizedDescription)
    }

    private func respond(_ pending: Pending, _ json: String) {
        pending.webView?.evaluateJavaScript("__UBCallbacks__.call(\(pending.callbackId), \(json))")
    }

    private static func positionJSON(location: CLLocation, place: CLPlacemark?) -> String {
        let address = place?.addressDictionary ?? [:]
        func field(_ key: String) -> String {
            (address[key] as? String ?? "").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let coordinate = location.coordinate
        return """
        {"position":{"timestamp":\(location.timestamp.timeIntervalSince1970 * 1000),\
        "coords":{"latitude":\(coordinate.latitude),"longitude":\(coordinate.longitude),\
        "altitude":\(location.altitude),"accuracy":\(location.horizontalAccuracy),\
        "altitudeAccuracy":\(location.verticalAccuracy),"heading":\(location.course),\
        "speed":\(location.speed)}},"address":{"street":"\(field("Street"))",\
        "city":"\(field("City"))","zip":"\(field("ZIP"))","country":"\(field("Country"))",\
        "state":"\(field("State"))","CountryCode":"\(field("CountryCode"))"}}
        """
    }
}

/// Copy of `Uebersicht/geolocation.js` from the Objective-C app, which is bundled from the
/// same file. Keep the two in step if the callback protocol ever changes.
let uebersichtGeolocationScript = #"""
window.__UBCallbacks__ = (function () {
    var api = {};
    var callbacks = {};
    var currentId = 0;

    api.register = function register(callback) {
        var id = currentId++;
        callbacks[id] = callback;
        return id;
    }

    api.remove = function remove(id) {
        delete callbacks[id];
    }

    api.call = function call(id) {
        if (callbacks[id]) {
            callbacks[id].apply(null, Array.prototype.slice.apply(arguments, [1]));
        }
    }

    return api;
}());

(function() {
    var geolocation = window.navigator.geolocation;
    var messageHandler = window.webkit.messageHandlers.geolocation;

    geolocation.getCurrentPosition = function getCurrentPosition(onPos, onErr) {
        var callbackId = __UBCallbacks__.register(function (pos) {
            onPos(pos);
            __UBCallbacks__.remove(callbackId);
            geolocation.clearWatch(callbackId);
        });

        messageHandler.postMessage({type: 'registerCallback', callbackId: callbackId});
    };

    geolocation.watchPosition = function watchPosition(onPos, onErr) {
        var callbackId = __UBCallbacks__.register(function (pos) {
            onPos(pos);
        });

        messageHandler.postMessage({type: 'registerCallback', callbackId: callbackId});

        return callbackId;
    };

    geolocation.clearWatch = function clearWatch(callbackId) {
        messageHandler.postMessage({type: 'removeCallback', callbackId: callbackId});
    };

    window.geolocation = geolocation;
}());
"""#
