//
//  ghostty-bridging-header.h
//  VVTerm
//
//  Bridging header to expose C APIs to Swift
//

#ifndef ghostty_bridging_header_h
#define ghostty_bridging_header_h

// ghostty/vt.h duplicates enum definitions from this public API header.
#include <ghostty.h>

// Import libssh2 for SSH connections
// Uses header search paths configured in Xcode build settings
#include <libssh2.h>
#include <libssh2_sftp.h>

#endif /* ghostty_bridging_header_h */
