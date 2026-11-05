import Foundation

/// InnerTube client identities, ported from SmartTube's AppClient/CLIENTS.
struct InnerTubeClient {
    let name: String          // clientName
    let version: String
    let nameId: Int           // X-YouTube-Client-Name
    let userAgent: String
    let referer: String?
    var screen: String = "WATCH"
    var extraClient: [String: Any] = [:]
    var browseExtra: [String: Any] = [:]

    var isTV: Bool { name.hasPrefix("TVHTML5") }
    var supportsAuth: Bool { name == "TVHTML5" }

    static let uaFireTV = "Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles Starboard/13, Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0"
    /// Old Cobalt UA: YouTube serves the non-TCL player with 5-digit signature timestamp.
    static let uaCobaltOld = "Mozilla/5.0 (DirectFB; Linux x86_64) Cobalt/4.13031-qa (unlike Gecko) Starboard/1"
    static let uaWeb = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let uaSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"

    private static let tvBrowseExtra: [String: Any] = [
        "tvAppInfo": ["appQuality": "TV_APP_QUALITY_FULL_ANIMATION", "zylonLeftNav": true],
        "webpSupport": false,
        "animatedWebpSupport": true
    ]

    /// Main TV client — supports sign-in. Used for browse/next/search/actions.
    static let tv = InnerTubeClient(name: "TVHTML5", version: "7.20260901.15.00", nameId: 7,
                                    userAgent: uaFireTV, referer: "https://www.youtube.com/tv",
                                    browseExtra: tvBrowseExtra)
    /// Downgraded TV client — used for playback (works with plain 5-digit sts + ejs solver).
    static let tvDowngraded = InnerTubeClient(name: "TVHTML5", version: "5.20260901", nameId: 7,
                                              userAgent: uaCobaltOld, referer: "https://www.youtube.com/tv",
                                              browseExtra: tvBrowseExtra)
    static let web = InnerTubeClient(name: "WEB", version: "2.20260907.06.00", nameId: 1,
                                     userAgent: uaWeb, referer: "https://www.youtube.com")
    static let webEmbed = InnerTubeClient(name: "WEB_EMBEDDED_PLAYER", version: "2.20260908.01.00", nameId: 56,
                                          userAgent: uaSafari, referer: "https://www.youtube.com", screen: "EMBED")
    static let mweb = InnerTubeClient(name: "MWEB", version: "2.20260907.05.00", nameId: 2,
                                      userAgent: "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)",
                                      referer: "https://m.youtube.com")
    static let ios = InnerTubeClient(name: "IOS", version: "21.26.4", nameId: 5,
                                     userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                                     referer: nil,
                                     extraClient: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"])
    static let androidVR = InnerTubeClient(name: "ANDROID_VR", version: "1.65.10", nameId: 28,
                                           userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
                                           referer: nil,
                                           extraClient: ["androidSdkVersion": 32, "osName": "Android", "osVersion": "12", "deviceMake": "Oculus", "deviceModel": "Quest 3"])
    static let webMusic = InnerTubeClient(name: "WEB_REMIX", version: "1.20260707.12.00", nameId: 67,
                                          userAgent: uaWeb, referer: "https://music.youtube.com")

    func refererURL(videoId: String?) -> String? {
        guard let referer else { return nil }
        guard let videoId else { return referer }
        if isTV { return "\(referer)/watch#/watch?v=\(videoId)" }
        if screen == "EMBED" { return "\(referer)/embed/\(videoId)?html5=1" }
        return "\(referer)/watch?v=\(videoId)"
    }
}
