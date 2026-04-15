#if DMUX_XCODE_BUILD
import Foundation

extension Foundation.Bundle {
    static var module: Bundle { .main }
}
#endif
