import Testing
import Foundation

@Suite("FormEncoder")
struct FormEncoderTests {
    @Test("Percent-encodes everything outside RFC 3986 unreserved characters, including + & = / %")
    func strictEncoding() {
        let body = FormEncoder.encode([
            (name: "grant_type", value: "authorization_code"),
            (name: "code", value: "a+b&c=d/e%f g"),
            (name: "redirect_uri", value: "http://localhost:1455/auth/callback"),
        ])
        #expect(String(decoding: body, as: UTF8.self)
            == "grant_type=authorization_code&code=a%2Bb%26c%3Dd%2Fe%25f%20g&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback")
    }

    @Test("Preserves field order and leaves unreserved characters alone")
    func orderAndUnreserved() {
        let body = FormEncoder.encode([(name: "z", value: "A-z_0.9~"), (name: "a", value: "")])
        #expect(String(decoding: body, as: UTF8.self) == "z=A-z_0.9~&a=")
    }
}
