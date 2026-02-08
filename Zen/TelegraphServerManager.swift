import Foundation
import Combine
import Telegraph
import Network
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS) || os(macOS)
import Darwin
#endif

class TelegraphServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var serverURL: String = ""
    @Published var errorMessage: String = ""
    @Published var localIPAddress: String = ""
    @Published var filesUploaded = false // Trigger sync when files are uploaded
    /// Full file URLs of audio files just uploaded via the server; app imports only these (no full scan).
    @Published var recentlyUploadedAudioURLs: [URL] = []
    
    private var server: Server?
    private let port: Int = 8080
    private var modelContainer: ModelContainer?
    private var faviconVersion: Int = 0 // Version number for cache busting
    
    init() {
        getLocalIPAddress()
    }
    
    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }
    
    func startServer() {
        guard !isRunning else {
            #if DEBUG
            print("Server is already running")
            #endif
            return
        }
        
        do {
            server = Server()
            
            // Serve files from the Documents directory
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let faviconURL = documentsURL.appendingPathComponent("favicon.ico")
            
            // Copy app icon to Documents when server starts for reliable access
            #if canImport(UIKit)
            // Helper function to resize image to favicon size
            func resizeImageForFavicon(_ image: UIImage, to size: CGSize) -> UIImage? {
                UIGraphicsBeginImageContextWithOptions(size, false, 0)
                defer { UIGraphicsEndImageContext() }
                image.draw(in: CGRect(origin: .zero, size: size))
                return UIGraphicsGetImageFromCurrentImageContext()
            }
            
            // Always try to copy/update the favicon when server starts
            var iconImage: UIImage?
            let faviconSize = CGSize(width: 64, height: 64) // Standard favicon size
            
            // Method 1: Try UIImage from asset catalog with various names
            let iconNames = ["AppIcon", "AppIcon-1024", "AppIcon-60@3x", "AppIcon-60@2x"]
            for iconName in iconNames {
                if let appIcon = UIImage(named: iconName) {
                    iconImage = resizeImageForFavicon(appIcon, to: faviconSize)
                    #if DEBUG
                    print("✅ Found icon using UIImage(named: '\(iconName)')")
                    #endif
                    break
                }
            }
            
            // Method 2: Try to access from bundle path (compiled location)
            if iconImage == nil {
                let bundlePath = Bundle.main.bundlePath
                let possiblePaths = [
                    (bundlePath as NSString).appendingPathComponent("AppIcon60x60@3x.png"),
                    (bundlePath as NSString).appendingPathComponent("AppIcon60x60@2x.png"),
                    (bundlePath as NSString).appendingPathComponent("AppIcon.png")
                ]
                
                for iconPath in possiblePaths {
                    if FileManager.default.fileExists(atPath: iconPath),
                       let image = UIImage(contentsOfFile: iconPath) {
                        iconImage = resizeImageForFavicon(image, to: faviconSize)
                        #if DEBUG
                        print("✅ Found icon at: \(iconPath)")
                        #endif
                        break
                    }
                }
            }

            // Method 3: Try resource path
            if iconImage == nil, let resourcePath = Bundle.main.resourcePath {
                let possiblePaths = [
                    (resourcePath as NSString).appendingPathComponent("Assets.xcassets/AppIcon.appiconset/Zen app design.png"),
                    (resourcePath as NSString).appendingPathComponent("Assets.xcassets/AppIcon.appiconset/Zen app design 1.png"),
                    (resourcePath as NSString).appendingPathComponent("Assets.xcassets/AppIcon.appiconset/Zen app design 2.png"),
                    (resourcePath as NSString).appendingPathComponent("AppIcon.png")
                ]
                
                for iconPath in possiblePaths {
                    #if DEBUG
                    print("🔍 Checking: \(iconPath)")
                    #endif
                    if FileManager.default.fileExists(atPath: iconPath),
                       let image = UIImage(contentsOfFile: iconPath) {
                        iconImage = resizeImageForFavicon(image, to: faviconSize)
                        #if DEBUG
                        print("✅ Found icon at: \(iconPath)")
                        #endif
                        break
                    }
                }
            }

            // Method 4: Create a simple yellow "Z" icon as fallback
            if iconImage == nil {
                #if DEBUG
                print("⚠️ Could not find app icon, creating fallback")
                #endif
                UIGraphicsBeginImageContextWithOptions(faviconSize, false, 0)
                defer { UIGraphicsEndImageContext() }
                
                if let context = UIGraphicsGetCurrentContext() {
                    // Yellow background
                    context.setFillColor(UIColor(red: 1.0, green: 0.76, blue: 0.03, alpha: 1.0).cgColor)
                    context.fill(CGRect(origin: .zero, size: faviconSize))
                    
                    // White "Z" text
                    let text = "Z" as NSString
                    let font = UIFont.boldSystemFont(ofSize: 48)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: UIColor.white
                    ]
                    let textSize = text.size(withAttributes: attributes)
                    let textRect = CGRect(
                        x: (faviconSize.width - textSize.width) / 2,
                        y: (faviconSize.height - textSize.height) / 2,
                        width: textSize.width,
                        height: textSize.height
                    )
                    text.draw(in: textRect, withAttributes: attributes)
                    
                    iconImage = UIGraphicsGetImageFromCurrentImageContext()
                    #if DEBUG
                    print("✅ Created fallback icon")
                    #endif
                }
            }
            
            // Convert to PNG data and save
            if let image = iconImage,
               let iconData = image.pngData() {
                do {
                    try iconData.write(to: faviconURL)
                    // Update version to force browser refresh
                    faviconVersion = Int(Date().timeIntervalSince1970)
                    #if DEBUG
                    print("✅ Saved favicon to: \(faviconURL.path), size: \(iconData.count) bytes")
                    #endif
                } catch {
                    #if DEBUG
                    print("⚠️ Failed to save favicon: \(error)")
                    #endif
                }
            } else {
                #if DEBUG
                print("⚠️ Could not create favicon")
                #endif
            }
            #endif
            
            // Add favicon route - serve app icon
            server?.route(.GET, "/favicon.ico") { (request: HTTPRequest) -> HTTPResponse in
                #if DEBUG
                print("🔍 Favicon requested: \(request.uri.path)")
                #endif
                
                // First try: Serve favicon from Documents directory (most reliable)
                if FileManager.default.fileExists(atPath: faviconURL.path),
                   let iconData = try? Data(contentsOf: faviconURL) {
                    #if DEBUG
                    print("✅ Serving favicon from Documents: \(faviconURL.path), size: \(iconData.count) bytes")
                    #endif
                    var response = HTTPResponse(.ok)
                    response.body = iconData
                    response.headers["Content-Type"] = "image/png"
                    response.headers["Content-Length"] = "\(iconData.count)"
                    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
                    response.headers["Pragma"] = "no-cache"
                    response.headers["Expires"] = "0"
                    let _ = { response = response }()
                    return response
                }
                
                // Fallback: Try to regenerate from UIImage
                #if canImport(UIKit)
                var iconData: Data?
                let iconNames = ["AppIcon", "AppIcon-1024"]
                for iconName in iconNames {
                    if let appIcon = UIImage(named: iconName),
                       let data = appIcon.pngData() {
                        iconData = data
                        #if DEBUG
                        print("✅ Generated favicon from UIImage(named: '\(iconName)')")
                        #endif
                        // Save for next time
                        try? data.write(to: faviconURL)
                        break
                    }
                }
                
                if let data = iconData {
                    var response = HTTPResponse(.ok)
                    response.body = data
                    response.headers["Content-Type"] = "image/png"
                    response.headers["Content-Length"] = "\(data.count)"
                    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
                    let _ = { response = response }()
                    return response
                }
                #endif
                
                #if DEBUG
                print("⚠️ Favicon not found, returning 204")
                #endif
                // Return 204 No Content (browser will use default)
                var response = HTTPResponse(.noContent)
                response.headers["Cache-Control"] = "no-cache"
                let _ = { response = response }()
                return response
            }
            
            // Add route to serve artwork
            server?.route(.GET, "artwork/*") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error")
                }
                
                let context = ModelContext(container)
                let requestPath = request.uri.path
                let songPath = String(requestPath.dropFirst(9)) // Remove "/artwork/" prefix
                let decodedPath = songPath.removingPercentEncoding ?? songPath
                
                let descriptor = FetchDescriptor<Song>()
                if let songs = try? context.fetch(descriptor),
                   let song = songs.first(where: { $0.url.path == decodedPath }),
                   let artworkData = song.artworkContainer?.data {
                    var response = HTTPResponse(.ok)
                    response.body = artworkData
                    response.headers["Content-Type"] = "image/jpeg"
                    response.headers["Cache-Control"] = "public, max-age=31536000"
                    let _ = { response = response }()
                    return response
                }
                
                return HTTPResponse(.notFound, content: "Artwork not found")
            }
            
            // Add route to serve files
            server?.route(.GET, "files/*") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self else {
                    return HTTPResponse(.internalServerError, content: "Server error")
                }
                
                // Get path from URI - Telegraph uses request.uri.path
                let requestPath = request.uri.path
                var path = String(requestPath.dropFirst(6)) // Remove "/files" prefix
                // Decode URL encoding
                path = path.removingPercentEncoding ?? path
                
                // Try multiple path variations
                var fileURL: URL?
                
                // First try: relative to Documents directory (most common)
                let relativePath = documentsURL.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: relativePath.path) {
                    fileURL = relativePath
                } else {
                    // Second try: if path contains Documents directory, use it directly
                    if path.contains("/Documents/") {
                        let directPath = URL(fileURLWithPath: path)
                        if FileManager.default.fileExists(atPath: directPath.path) {
                            fileURL = directPath
                        }
                    }
                    
                    // Third try: search by filename only
                    if fileURL == nil {
                        let fileName = URL(fileURLWithPath: path).lastPathComponent
                        let searchURL = documentsURL.appendingPathComponent(fileName)
                        if FileManager.default.fileExists(atPath: searchURL.path) {
                            fileURL = searchURL
                        }
                    }
                }
                
                // Check if file exists
                guard let fileURL = fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
                    return HTTPResponse(.notFound, content: "File not found: \(path)")
                }
                
                // Check if it's a directory
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                
                if isDirectory.boolValue {
                    return self.directoryListing(for: fileURL)
                }
                
                // Return the file - Telegraph's HTTPResponse.body accepts Data directly!
                if let data = try? Data(contentsOf: fileURL) {
                    // Determine content type based on file extension
                    let ext = fileURL.pathExtension.lowercased()
                    let contentType: String
                    switch ext {
                    case "mp3":
                        contentType = "audio/mpeg"
                    case "m4a":
                        contentType = "audio/mp4"
                    case "wav":
                        contentType = "audio/wav"
                    case "flac":
                        contentType = "audio/flac"
                    case "aac":
                        contentType = "audio/aac"
                    default:
                        contentType = "application/octet-stream"
                    }
                    
                    // Create response with body data
                    // Note: Setting body and headers does mutate the response, but compiler may not detect it
                    var response = HTTPResponse(.ok)
                    response.body = data
                    response.headers["Content-Type"] = contentType
                    response.headers["Accept-Ranges"] = "bytes"
                    response.headers["Content-Length"] = "\(data.count)"
                    // Force mutation detection by reassigning
                    let _ = { response = response }()
                    
                    return response
                } else {
                    return HTTPResponse(.internalServerError, content: "Could not read file")
                }
            }
            
            // Add root route - redirect to library
            server?.route(.GET, "/") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                // Redirect to library page
                return self.libraryView(container: container)
            }
            
            // Add library route (all songs)
            server?.route(.GET, "/library") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                // Parse query parameters
                var page = 1
                var searchQuery = ""
                if let query = request.uri.query {
                    let components = query.components(separatedBy: "&")
                    for component in components {
                        if component.hasPrefix("page=") {
                            page = Int(String(component.dropFirst(5))) ?? 1
                        } else if component.hasPrefix("search=") {
                            searchQuery = String(component.dropFirst(7))
                                .replacingOccurrences(of: "+", with: " ")
                                .removingPercentEncoding ?? ""
                        }
                    }
                }
                return self.libraryView(container: container, searchQuery: searchQuery, page: page)
            }
            
            // Add artists route
            server?.route(.GET, "/artists") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.artistsView(container: container)
            }
            
            // Add albums route
            server?.route(.GET, "/albums") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.albumsView(container: container)
            }
            
            // Add playlists route
            server?.route(.GET, "/playlists") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.playlistsView(container: container)
            }
            
            // Add artist detail route
            server?.route(.GET, "/artist/*") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                let artistName = String(request.uri.path.dropFirst(8)) // Remove "/artist/" prefix
                let decodedArtist = artistName.removingPercentEncoding ?? artistName
                return self.artistDetailView(container: container, artist: decodedArtist)
            }
            
            // Add album detail route
            server?.route(.GET, "/album/*") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                let albumName = String(request.uri.path.dropFirst(7)) // Remove "/album/" prefix
                let decodedAlbum = albumName.removingPercentEncoding ?? albumName
                return self.albumDetailView(container: container, album: decodedAlbum)
            }
            
            // Add playlist detail/edit route - check if path ends with /edit
            server?.route(.GET, "/playlist/*") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                let path = request.uri.path
                
                // Check if this is an edit request
                if path.hasSuffix("/edit") {
                    // Extract playlist name: remove "/playlist/" prefix and "/edit" suffix
                    let playlistName = String(path.dropFirst(10).dropLast(5))
                    let decodedPlaylist = playlistName.removingPercentEncoding ?? playlistName
                    #if DEBUG
                    print("🔍 Edit route - path: \(path), decoded: \(decodedPlaylist)")
                    #endif
                    return self.playlistEditView(container: container, playlistName: decodedPlaylist)
                } else {
                    // Regular playlist detail view
                    let playlistName = String(path.dropFirst(10)) // Remove "/playlist/" prefix
                    let decodedPlaylist = playlistName.removingPercentEncoding ?? playlistName
                    #if DEBUG
                    print("🔍 Detail route - path: \(path), decoded: \(decodedPlaylist)")
                    #endif
                    return self.playlistDetailView(container: container, playlistName: decodedPlaylist)
                }
            }
            
            // Add delete route (for songs)
            server?.route(.POST, "/delete") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.handleDelete(container: container, request: request)
            }
            
            // Add playlist create route
            server?.route(.POST, "/playlist/create") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.handleCreatePlaylist(container: container, request: request)
            }
            
            // Add playlist delete route
            server?.route(.POST, "/playlist/delete") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.handleDeletePlaylist(container: container, request: request)
            }
            
            // Add playlist rename route
            server?.route(.POST, "/playlist/rename") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.handleRenamePlaylist(container: container, request: request)
            }
            
            // Add song to playlist route
            server?.route(.POST, "/playlist/add-song") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.handleAddSongToPlaylist(container: container, request: request)
            }
            
            // Remove song from playlist route
            server?.route(.POST, "/playlist/remove-song") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self, let container = self.modelContainer else {
                    return HTTPResponse(.internalServerError, content: "Server error: Model container not available")
                }
                return self.handleRemoveSongFromPlaylist(container: container, request: request)
            }
            
            // Add upload page route
            server?.route(.GET, "/upload") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self else {
                    return HTTPResponse(.internalServerError, content: "Server error")
                }
                let html = """
                <!DOCTYPE html>
                <html>
                <head>
                    <title>Upload Files - Zen</title>
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    \(self.faviconLink())
                    \(self.commonCSS())
                    <style>
                        .upload-form { margin: 30px 0; }
                        .drag-drop-area {
                            margin: 20px 0;
                            padding: 60px 20px;
                            width: 100%;
                            border: 3px dashed rgba(255, 193, 7, 0.4);
                            border-radius: 12px;
                            background: rgba(255, 255, 255, 0.03);
                            text-align: center;
                            cursor: pointer;
                            transition: all 0.3s;
                            position: relative;
                        }
                        .drag-drop-area:hover,
                        .drag-drop-area.dragover {
                            border-color: #FFC107;
                            background: rgba(255, 193, 7, 0.1);
                            transform: scale(1.01);
                        }
                        .drag-drop-area p {
                            color: rgba(255, 255, 255, 0.7);
                            font-size: 16px;
                            margin: 10px 0;
                        }
                        .drag-drop-area .icon {
                            font-size: 48px;
                            margin-bottom: 16px;
                            color: #FFC107;
                        }
                        input[type="file"] { 
                            position: absolute;
                            top: 0;
                            left: 0;
                            width: 100%;
                            height: 100%;
                            opacity: 0;
                            cursor: pointer;
                            z-index: 10;
                        }
                        .file-input-label {
                            display: inline-block;
                            margin-top: 20px;
                            padding: 12px 24px;
                            background: rgba(255, 193, 7, 0.2);
                            color: #FFC107;
                            border: 2px solid #FFC107;
                            border-radius: 8px;
                            cursor: pointer;
                            font-weight: 600;
                            transition: all 0.2s;
                            position: relative;
                            z-index: 5;
                        }
                        .file-input-label:hover {
                            background: rgba(255, 193, 7, 0.3);
                            transform: translateY(-2px);
                        }
                        button[type="submit"] { 
                            background: #FFC107; 
                            color: #000; 
                            padding: 14px 28px; 
                            border: none; 
                            border-radius: 8px; 
                            font-size: 16px; 
                            font-weight: 600;
                            cursor: pointer; 
                            width: 100%;
                            margin-top: 20px;
                            transition: all 0.2s;
                        }
                        button[type="submit"]:hover { 
                            background: #FFB300; 
                            transform: translateY(-1px);
                            box-shadow: 0 4px 12px rgba(255, 193, 7, 0.3);
                        }
                        button[type="submit"]:disabled {
                            opacity: 0.6;
                            cursor: not-allowed;
                            transform: none;
                        }
                        .upload-progress {
                            display: none;
                            margin: 24px 0;
                            padding: 20px;
                            background: rgba(255, 255, 255, 0.05);
                            border-radius: 12px;
                            border: 1px solid rgba(255, 193, 7, 0.3);
                        }
                        .upload-progress.visible {
                            display: block;
                        }
                        .upload-progress .progress-bar-wrap {
                            height: 12px;
                            background: rgba(255, 255, 255, 0.1);
                            border-radius: 6px;
                            overflow: hidden;
                            margin: 12px 0 8px 0;
                        }
                        .upload-progress .progress-bar-fill {
                            height: 100%;
                            background: linear-gradient(90deg, #FFC107, #FFB300);
                            border-radius: 6px;
                            width: 0%;
                            transition: width 0.15s ease-out;
                        }
                        .upload-progress .progress-text {
                            color: rgba(255, 255, 255, 0.85);
                            font-size: 14px;
                            margin-top: 4px;
                        }
                        .back-link {
                            display: inline-block;
                            margin-top: 20px;
                            color: #FFC107;
                            text-decoration: none;
                        }
                        .back-link:hover {
                            color: #FFB300;
                            text-decoration: underline;
                        }
                    </style>
                </head>
                <body>
                    <div class="app-container">
                        \(self.navigationBar())
                        <div class="main-content">
                            <div class="container">
                                <h1>📤 Upload Files</h1>
                                <form action="/upload" method="post" enctype="multipart/form-data" class="upload-form" id="uploadForm">
                                    <div class="drag-drop-area" id="dragDropArea">
                                        <div class="icon">📁</div>
                                        <p><strong>Drag and drop audio files or playlists here</strong></p>
                                        <p style="font-size: 14px;">or</p>
                                        <label for="fileInput" class="file-input-label">Choose Files</label>
                                        <input type="file" id="fileInput" name="file" accept="audio/*,.mp3,.m4a,.wav,.flac,.aac,.m3u,.m3u8" multiple>
                                    </div>
                                    <div class="upload-progress" id="uploadProgress">
                                        <div class="progress-text" id="uploadProgressText">Preparing upload...</div>
                                        <div class="progress-bar-wrap">
                                            <div class="progress-bar-fill" id="uploadProgressBar"></div>
                                        </div>
                                    </div>
                                    <button type="submit" id="uploadSubmitBtn">Upload Files</button>
                                </form>
                                <a href="/library" class="back-link">← Back to Library</a>
                            </div>
                        </div>
                    </div>
                    <script>
                        const dragDropArea = document.getElementById('dragDropArea');
                        const fileInput = document.getElementById('fileInput');
                        const uploadForm = document.getElementById('uploadForm');
                        const uploadProgress = document.getElementById('uploadProgress');
                        const uploadProgressBar = document.getElementById('uploadProgressBar');
                        const uploadProgressText = document.getElementById('uploadProgressText');
                        const uploadSubmitBtn = document.getElementById('uploadSubmitBtn');
                        
                        function startUpload() {
                            if (!fileInput.files || fileInput.files.length === 0) {
                                alert('Please select one or more files first.');
                                return;
                            }
                            const formData = new FormData(uploadForm);
                            uploadProgress.classList.add('visible');
                            uploadProgressBar.style.width = '0%';
                            uploadProgressText.textContent = 'Uploading... 0%';
                            uploadSubmitBtn.disabled = true;
                            fileInput.disabled = true;
                            
                            const xhr = new XMLHttpRequest();
                            xhr.open('POST', '/upload');
                            xhr.upload.addEventListener('progress', (e) => {
                                if (e.lengthComputable) {
                                    const pct = Math.round((e.loaded / e.total) * 100);
                                    uploadProgressBar.style.width = pct + '%';
                                    uploadProgressText.textContent = 'Uploading... ' + pct + '%';
                                } else {
                                    uploadProgressText.textContent = 'Uploading...';
                                }
                            });
                            xhr.addEventListener('load', () => {
                                uploadProgressBar.style.width = '100%';
                                uploadProgressText.textContent = 'Complete. Loading result...';
                                if (xhr.status === 200) {
                                    const parser = new DOMParser();
                                    const doc = parser.parseFromString(xhr.responseText, 'text/html');
                                    const resultMain = doc.querySelector('.main-content .container');
                                    if (resultMain) {
                                        document.querySelector('.main-content .container').innerHTML = resultMain.innerHTML;
                                        if (typeof initMobileMenu === 'function') initMobileMenu();
                                    } else {
                                        document.body.innerHTML = xhr.responseText;
                                    }
                                } else {
                                    uploadProgressText.textContent = 'Upload failed (status ' + xhr.status + ').';
                                    uploadSubmitBtn.disabled = false;
                                    fileInput.disabled = false;
                                }
                            });
                            xhr.addEventListener('error', () => {
                                uploadProgressText.textContent = 'Upload failed (network error).';
                                uploadSubmitBtn.disabled = false;
                                fileInput.disabled = false;
                            });
                            xhr.send(formData);
                        }
                        
                        uploadForm.addEventListener('submit', (e) => {
                            e.preventDefault();
                            startUpload();
                        });
                        
                        // Drag and drop handlers
                        dragDropArea.addEventListener('dragover', (e) => {
                            e.preventDefault();
                            dragDropArea.classList.add('dragover');
                        });
                        
                        dragDropArea.addEventListener('dragleave', () => {
                            dragDropArea.classList.remove('dragover');
                        });
                        
                        dragDropArea.addEventListener('drop', (e) => {
                            e.preventDefault();
                            dragDropArea.classList.remove('dragover');
                            const files = e.dataTransfer.files;
                            if (files.length > 0) {
                                fileInput.files = files;
                                const count = files.length;
                                dragDropArea.querySelector('p').textContent = count + ' file' + (count > 1 ? 's' : '') + ' selected';
                                startUpload();
                            }
                        });
                        
                        // Update label when files are selected
                        fileInput.addEventListener('change', (e) => {
                            if (e.target.files.length > 0) {
                                const count = e.target.files.length;
                                dragDropArea.querySelector('p').textContent = count + ' file' + (count > 1 ? 's' : '') + ' selected';
                            }
                        });
                    </script>
                    \(self.mobileMenuScript())
                </body>
                </html>
                """
                let htmlData = html.data(using: .utf8) ?? Data()
                var response = HTTPResponse(.ok)
                response.body = htmlData
                response.headers["Content-Type"] = "text/html; charset=utf-8"
                let _ = { response = response }()
                return response
            }
            
            // Add upload handler route (POST)
            server?.route(.POST, "/upload") { [weak self] (request: HTTPRequest) -> HTTPResponse in
                guard let self = self else {
                    return HTTPResponse(.internalServerError, content: "Server error")
                }
                
                let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                var uploadedFiles: [String] = []
                var uploadedAudioFiles: [String] = []
                var playlistResultsHTML: [String] = []
                var errors: [String] = []
                
                // Parse multipart form data
                if let contentType = request.headers["Content-Type"], contentType.contains("multipart/form-data") {
                    let boundary = contentType.components(separatedBy: "boundary=").last ?? ""
                    let bodyData = request.body
                    
                    // Parse multipart data
                    let parts = self.parseMultipartData(bodyData, boundary: boundary)
                    
                    // If we're importing playlists, we need access to the database + current library
                    let containerForPlaylists = self.modelContainer
                    
                    for part in parts {
                        if let filename = part["filename"] as? String, !filename.isEmpty,
                           let data = part["data"] as? Data {
                            // Ensure filename is clean (no percent-encoding)
                            // This prevents issues where AVPlayer can't find files due to encoding mismatches
                            let cleanFilename = filename.removingPercentEncoding ?? filename
                            let ext = (cleanFilename as NSString).pathExtension.lowercased()
                            
                            // Playlist import (.m3u / .m3u8): create a playlist from existing library songs
                            if ext == "m3u" || ext == "m3u8" {
                                guard let container = containerForPlaylists else {
                                    errors.append("Uploaded \(cleanFilename) but playlist import is not ready (database not configured). Open the Zen app once, then try again.")
                                    continue
                                }
                                
                                // Use a semaphore to ensure synchronous execution on main thread
                                let semaphore = DispatchSemaphore(value: 0)
                                var importResult: ImportedPlaylistResult?
                                var importError: Error?
                                
                                DispatchQueue.main.async {
                                    let context = ModelContext(container)
                                    do {
                                        // Fetch songs and playlists in the same context we'll use for insertion
                                        let songs = try context.fetch(FetchDescriptor<Song>())
                                        let songIndex = self.buildSongFilenameIndex(songs: songs)
                                        
                                        let playlists = try context.fetch(FetchDescriptor<Playlist>())
                                        var existingPlaylistNamesLowercased = Set(playlists.map { $0.name.lowercased() })
                                        var nextPlaylistSortOrder = (playlists.map { $0.sortOrder }.max() ?? -1) + 1
                                        
                                        let result = try self.importPlaylistFromM3U(
                                            context: context,
                                            playlistFilename: cleanFilename,
                                            data: data,
                                            songIndexByFilenameLowercased: songIndex,
                                            existingPlaylistNamesLowercased: &existingPlaylistNamesLowercased,
                                            nextSortOrder: &nextPlaylistSortOrder
                                        )
                                        importResult = result
                                    } catch {
                                        importError = error
                                    }
                                    semaphore.signal()
                                }
                                
                                // Wait for the import to complete
                                semaphore.wait()
                                
                                if let result = importResult {
                                    playlistResultsHTML.append(
                                        "<li><strong>\(result.playlistName.escapedHTML())</strong>: added \(result.matchedCount) song\(result.matchedCount == 1 ? "" : "s")\(result.missingCount > 0 ? ", \(result.missingCount) missing" : "")</li>"
                                    )
                                    uploadedFiles.append(cleanFilename)
                                } else if let error = importError {
                                    errors.append("Failed to import playlist \(cleanFilename): \(error.localizedDescription)")
                                }
                                
                                continue
                            }
                            
                            // Create a clean file URL using fileURLWithPath to ensure proper encoding
                            // This ensures the URL stored in the database will match the actual file path
                            let fileURL = documentsURL.appendingPathComponent(cleanFilename)
                            
                            do {
                                try data.write(to: fileURL)
                                uploadedFiles.append(cleanFilename)
                                uploadedAudioFiles.append(cleanFilename)
                            } catch {
                                errors.append("Failed to save \(cleanFilename): \(error.localizedDescription)")
                            }
                        }
                    }
                }
                
                // Notify that files were uploaded (trigger sync in app)
                if !uploadedAudioFiles.isEmpty {
                    let audioURLs = uploadedAudioFiles.map { documentsURL.appendingPathComponent($0) }
                    DispatchQueue.main.async { [weak self] in
                        self?.recentlyUploadedAudioURLs = audioURLs
                        self?.filesUploaded = true
                        // Reset flag after a brief moment so it can trigger again
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self?.filesUploaded = false
                        }
                    }
                }
                
                // Create response page
                var messageHTML = ""
                if !uploadedFiles.isEmpty {
                    var successDetails = ""
                    if !uploadedAudioFiles.isEmpty {
                        let audioList = uploadedAudioFiles.joined(separator: ", ")
                        successDetails += "Uploaded: \(audioList)<br><small>Audio files will be automatically imported into your music library.</small>"
                    }
                    if !playlistResultsHTML.isEmpty {
                        if !successDetails.isEmpty { successDetails += "<br><br>" }
                        successDetails += "<strong>Playlists imported:</strong><ul>\(playlistResultsHTML.joined())</ul>"
                    }
                    messageHTML += "<div class=\"message success\"><strong>Success!</strong> \(successDetails)</div>"
                }
                if !errors.isEmpty {
                    messageHTML += "<div class=\"message error\"><strong>Errors:</strong><ul>\(errors.map { "<li>\($0)</li>" }.joined())</ul></div>"
                }
                
                let html = """
                <!DOCTYPE html>
                <html>
                <head>
                    <title>Upload Result - Zen</title>
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    \(self.faviconLink())
                    \(self.commonCSS())
                    <style>
                        .message { padding: 15px; margin: 20px 0; border-radius: 8px; }
                        .success { background: rgba(255, 193, 7, 0.2); color: #FFC107; border: 1px solid rgba(255, 193, 7, 0.4); }
                        .error { background: rgba(220, 53, 69, 0.2); color: #ff6b7a; border: 1px solid rgba(220, 53, 69, 0.4); }
                        .message strong { display: block; margin-bottom: 8px; }
                        .message ul { margin: 10px 0 0 20px; }
                        .action-links {
                            margin-top: 25px;
                            display: flex;
                            gap: 15px;
                            flex-wrap: wrap;
                        }
                        .action-links a {
                            color: #FFC107;
                            text-decoration: none;
                            font-weight: 500;
                        }
                        .action-links a:hover {
                            color: #FFB300;
                            text-decoration: underline;
                        }
                    </style>
                </head>
                <body>
                    <div class="app-container">
                        \(self.navigationBar())
                        <div class="main-content">
                            <div class="container">
                                <h1>📤 Upload Result</h1>
                                \(messageHTML)
                                <div class="action-links">
                                    <a href="/upload">Upload More Files</a>
                                    <a href="/library">Back to Library</a>
                                </div>
                            </div>
                        </div>
                    </div>
                    \(self.mobileMenuScript())
                </body>
                </html>
                """
                let htmlData = html.data(using: .utf8) ?? Data()
                var response = HTTPResponse(.ok)
                response.body = htmlData
                response.headers["Content-Type"] = "text/html; charset=utf-8"
                let _ = { response = response }()
                return response
            }
            
            // Start the server
            try server?.start(port: port)
            
            // Update published properties on main thread for SwiftUI
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isRunning = true
                self.serverURL = "http://\(self.localIPAddress):\(self.port)"
                self.errorMessage = ""
            }
            
            #if DEBUG
            print("✅ Telegraph server started on port \(port)")
            print("🌐 Server URL: http://\(localIPAddress):\(port)")
            #endif
            
        } catch {
            // Update error on main thread
            DispatchQueue.main.async {
                self.errorMessage = "Failed to start server: \(error.localizedDescription)"
                self.isRunning = false
            }
            #if DEBUG
            print("❌ Error starting server: \(error)")
            #endif
        }
    }
    
    func stopServer() {
        server?.stop()
        server = nil
        
        // Update published properties on main thread for SwiftUI
        DispatchQueue.main.async {
            self.isRunning = false
            self.serverURL = ""
        }
        
        #if DEBUG
        print("🛑 Server stopped")
        #endif
    }
    
    private func getLocalIPAddress() {
        // Try to get IP address from network interfaces
        var address = "localhost"
        
        #if os(iOS) || os(macOS)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            DispatchQueue.main.async {
                self.localIPAddress = address
            }
            return
        }
        guard let firstAddr = ifaddr else {
            DispatchQueue.main.async {
                self.localIPAddress = address
            }
            return
        }
        
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            // Look for IPv4 address on WiFi or Ethernet interface
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 is WiFi on iOS, en1 might be Ethernet on macOS
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    // Skip localhost/loopback addresses
                    if !address.hasPrefix("127.") && !address.hasPrefix("169.254.") {
                        break
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        #endif
        
        DispatchQueue.main.async {
            self.localIPAddress = address
        }
    }
    
    private func parseMultipartData(_ data: Data, boundary: String) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        let boundaryMarker = ("--" + boundary).data(using: .utf8)!
        
        // Find all boundary positions
        var positions: [Int] = []
        var searchIndex = data.startIndex
        
        while searchIndex < data.endIndex {
            if let range = data.range(of: boundaryMarker, options: [], in: searchIndex..<data.endIndex) {
                positions.append(range.lowerBound)
                searchIndex = range.upperBound
            } else {
                break
            }
        }
        
        // Parse each part
        for i in 0..<positions.count {
            let partStart = positions[i] + boundaryMarker.count
            let partEnd = (i + 1 < positions.count) ? positions[i + 1] : data.endIndex
            
            // Skip \r\n after boundary
            var headerStart = partStart
            if headerStart < data.endIndex - 1 && data[headerStart] == 13 && data[headerStart + 1] == 10 {
                headerStart += 2
            }
            
            // Find header/body separator (\r\n\r\n)
            let separator = "\r\n\r\n".data(using: .utf8)!
            guard let separatorRange = data.range(of: separator, options: [], in: headerStart..<partEnd) else {
                continue
            }
            
            let headerData = data[headerStart..<separatorRange.lowerBound]
            let bodyStart = separatorRange.upperBound
            
            // Extract filename from headers
            var filename: String?
            if let headerString = String(data: headerData, encoding: .utf8) {
                let lines = headerString.components(separatedBy: "\r\n")
                for line in lines {
                    if line.lowercased().contains("content-disposition:") {
                        // Extract filename="..."
                        if let filenameMatch = line.range(of: #"filename="([^"]+)""#, options: .regularExpression) {
                            let match = String(line[filenameMatch])
                            let extractedFilename = match.replacingOccurrences(of: "filename=\"", with: "").replacingOccurrences(of: "\"", with: "")
                            // Decode percent-encoding in filename (e.g., "My%20Song.mp3" -> "My Song.mp3")
                            // This ensures the filename on disk matches what we expect
                            filename = extractedFilename.removingPercentEncoding ?? extractedFilename
                        }
                    }
                }
            }
            
            // Extract body data (remove trailing \r\n before next boundary)
            var bodyEnd = partEnd
            if bodyEnd >= 2 && data[bodyEnd - 2] == 13 && data[bodyEnd - 1] == 10 {
                bodyEnd -= 2
            }
            
            if let filename = filename, bodyStart < bodyEnd {
                let fileData = Data(data[bodyStart..<bodyEnd])
                parts.append(["filename": filename, "data": fileData])
            }
        }
        
        return parts
    }
    
    // MARK: - Playlist import (.m3u / .m3u8)
    
    private func buildSongFilenameIndex(songs: [Song]) -> [String: Song] {
        var index: [String: Song] = [:]
        index.reserveCapacity(songs.count)
        
        for song in songs {
            let key = song.url.lastPathComponent.lowercased()
            // If there are duplicates, keep the first one (stable)
            if index[key] == nil {
                index[key] = song
            }
        }
        
        return index
    }
    
    private struct ImportedPlaylistResult {
        let playlistName: String
        let matchedCount: Int
        let missingCount: Int
    }
    
    private func importPlaylistFromM3U(
        context: ModelContext,
        playlistFilename: String,
        data: Data,
        songIndexByFilenameLowercased: [String: Song],
        existingPlaylistNamesLowercased: inout Set<String>,
        nextSortOrder: inout Int
    ) throws -> ImportedPlaylistResult {
        let baseName = ((playlistFilename as NSString).deletingPathExtension).trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse folder hierarchy from filename (format: folder#sub-folder#playlist.m3u)
        let components = baseName.components(separatedBy: "#")
        let playlistName = components.last ?? "Imported Playlist"
        let folderPath = components.dropLast() // All components except the last one (playlist name)

        let desiredName = playlistName.isEmpty ? "Imported Playlist" : playlistName
        let uniqueName = makeUniquePlaylistName(desiredName, existingLowercased: &existingPlaylistNamesLowercased)

        let lines = decodeM3UTextLines(data: data)
        let entries = parseM3UEntries(lines: lines)

        var matchedSongs: [Song] = []
        matchedSongs.reserveCapacity(entries.count)

        var seenSongIDs = Set<URL>()
        var missingCount = 0

        for entry in entries {
            guard let filename = filenameFromM3UEntry(entry) else { continue }
            let key = filename.lowercased()
            if let song = songIndexByFilenameLowercased[key] {
                // Keep order; avoid duplicates
                if !seenSongIDs.contains(song.id) {
                    matchedSongs.append(song)
                    seenSongIDs.insert(song.id)
                }
            } else {
                missingCount += 1
            }
        }

        // Find or create the folder hierarchy
        var parentFolder: Folder? = nil
        if !folderPath.isEmpty {
            parentFolder = try findOrCreateFolderHierarchy(context: context, path: Array(folderPath))
        }

        // Create playlist and attach songs
        let playlist = Playlist(name: uniqueName, sortOrder: nextSortOrder)
        playlist.songs = matchedSongs
        playlist.parentFolder = parentFolder

        // If inside a folder, add to folder's playlists array
        if let folder = parentFolder {
            folder.playlists.append(playlist)
        }

        context.insert(playlist)
        try context.save()
        // Set order after save so playlist has permanent persistentModelID
        setPlaylistOrderFromSongs(playlist: playlist, songs: matchedSongs)

        existingPlaylistNamesLowercased.insert(uniqueName.lowercased())
        nextSortOrder += 1

        return ImportedPlaylistResult(
            playlistName: uniqueName,
            matchedCount: matchedSongs.count,
            missingCount: missingCount
        )
    }

    /// Finds or creates a folder hierarchy from an array of folder names.
    /// For example, ["Music", "Rock", "Classic"] creates Music > Rock > Classic
    private func findOrCreateFolderHierarchy(context: ModelContext, path: [String]) throws -> Folder? {
        guard !path.isEmpty else { return nil }

        var currentParent: Folder? = nil

        for folderName in path {
            let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            // Try to find existing folder at this level
            let existingFolder = try findFolder(context: context, name: trimmedName, parent: currentParent)

            if let folder = existingFolder {
                currentParent = folder
            } else {
                // Create new folder
                let newFolder = Folder(name: trimmedName, sortOrder: 0, parent: currentParent)

                // If has parent, add to parent's subFolders
                if let parent = currentParent {
                    let nextOrder = parent.subFolders.map { $0.sortOrder }.max() ?? -1
                    newFolder.sortOrder = nextOrder + 1
                    parent.subFolders.append(newFolder)
                } else {
                    // Root level folder - get next sort order
                    let rootFolders = try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.parent == nil }))
                    let nextOrder = rootFolders.map { $0.sortOrder }.max() ?? -1
                    newFolder.sortOrder = nextOrder + 1
                }

                context.insert(newFolder)
                try context.save()
                currentParent = newFolder
            }
        }

        return currentParent
    }

    /// Finds a folder by name at a specific level (with given parent, or root if parent is nil)
    private func findFolder(context: ModelContext, name: String, parent: Folder?) throws -> Folder? {
        let nameLowercased = name.lowercased()

        if let parent = parent {
            // Search within parent's subFolders
            return parent.subFolders.first { $0.name.lowercased() == nameLowercased }
        } else {
            // Search root-level folders
            let rootFolders = try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.parent == nil }))
            return rootFolders.first { $0.name.lowercased() == nameLowercased }
        }
    }
    
    private func makeUniquePlaylistName(_ desired: String, existingLowercased: inout Set<String>) -> String {
        var candidate = desired
        var suffix = 2
        
        while existingLowercased.contains(candidate.lowercased()) {
            candidate = "\(desired) (\(suffix))"
            suffix += 1
        }
        
        return candidate
    }
    
    private func decodeM3UTextLines(data: Data) -> [String] {
        // .m3u8 is typically UTF-8; .m3u is often UTF-8 but may be Latin-1.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
    
    private func parseM3UEntries(lines: [String]) -> [String] {
        var entries: [String] = []
        entries.reserveCapacity(lines.count)
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue } // #EXTM3U, #EXTINF, etc.
            entries.append(line)
        }
        
        return entries
    }
    
    private func filenameFromM3UEntry(_ entry: String) -> String? {
        // Handle Windows backslashes and strip quotes
        var cleaned = entry.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        cleaned = cleaned.replacingOccurrences(of: "\\", with: "/")
        
        // If it's a URL, try URL parsing first
        if let url = URL(string: cleaned), url.scheme != nil {
            let last = url.lastPathComponent
            return last.isEmpty ? nil : (last.removingPercentEncoding ?? last)
        }
        
        // Otherwise treat as file path
        let last = (cleaned as NSString).lastPathComponent
        let decoded = last.removingPercentEncoding ?? last
        return decoded.isEmpty ? nil : decoded
    }
    
    private func directoryListing(for url: URL) -> HTTPResponse {
        let fileManager = FileManager.default
        var items: [String] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            items = contents.map { $0.lastPathComponent }
        } catch {
            return HTTPResponse(.internalServerError, content: "Could not list directory")
        }
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Files</title></head>
        <body>
            <h1>Files</h1>
            <ul>
                \(items.map { "<li><a href=\"/files/\($0)\">\($0)</a></li>" }.joined(separator: "\n"))
            </ul>
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        // Note: Setting body and headers does mutate the response, but compiler may not detect it
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        // Force mutation detection by reassigning
        let _ = { response = response }()
        return response
    }
    
    // MARK: - Shared Styles and Components
    
    private func faviconLink() -> String {
        // Use version number for cache busting (only changes when server restarts)
        return """
        <link rel="icon" type="image/png" href="/favicon.ico?v=\(faviconVersion)">
        <link rel="shortcut icon" type="image/png" href="/favicon.ico?v=\(faviconVersion)">
        <link rel="apple-touch-icon" href="/favicon.ico?v=\(faviconVersion)">
        """
    }
    
    private func commonCSS() -> String {
        return """
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { 
                font-family: 'Circular', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif; 
                background: #121212; 
                color: #fff; 
                min-height: 100vh;
                overflow-x: hidden;
            }
            .app-container {
                display: flex;
                min-height: 100vh;
                height: auto;
                overflow: hidden;
            }
            .sidebar {
                width: 240px;
                background: #000;
                padding: 24px 16px;
                overflow-y: auto;
                position: fixed;
                height: 100vh;
                z-index: 100;
            }
            .sidebar-logo {
                padding: 0 16px 24px;
                margin-bottom: 24px;
                border-bottom: 1px solid rgba(255, 255, 255, 0.1);
            }
            .sidebar-logo h2 {
                font-size: 24px;
                font-weight: 700;
                color: #fff;
                letter-spacing: -0.5px;
            }
            .nav { 
                display: flex; 
                flex-direction: column;
                gap: 8px;
            }
            .nav a { 
                padding: 12px 16px; 
                color: #FFC107; 
                text-decoration: none; 
                font-weight: 600;
                font-size: 18px;
                border-radius: 4px;
                transition: all 0.2s;
                display: flex;
                align-items: center;
                gap: 16px;
            }
            .nav a:hover { 
                color: #FFC107;
                background: rgba(255, 193, 7, 0.1);
            }
            .main-content {
                margin-left: 240px;
                flex: 1;
                background: linear-gradient(180deg, #1e1e1e 0%, #121212 100%);
                min-height: 100vh;
                padding-bottom: 100px;
                overflow-y: auto;
                height: auto;
            }
            .top-bar {
                background: rgba(0, 0, 0, 0.3);
                backdrop-filter: blur(10px);
                padding: 16px 32px;
                position: sticky;
                top: 0;
                z-index: 50;
                display: flex;
                align-items: center;
                justify-content: space-between;
            }
            .container { 
                padding: 24px 32px;
                max-width: 1200px;
                margin: 0 auto;
            }
            h1 { 
                color: #fff; 
                margin-bottom: 8px;
                font-weight: 700;
                font-size: 32px;
                letter-spacing: -0.5px;
            }
            .search-container {
                margin-bottom: 24px;
            }
            .search-box {
                width: 100%;
                max-width: 364px;
                padding: 12px 40px 12px 16px;
                background: rgba(255, 255, 255, 0.1);
                border: none;
                border-radius: 500px;
                color: #fff;
                font-size: 14px;
                outline: none;
                transition: all 0.2s;
            }
            .search-box:focus {
                background: rgba(255, 255, 255, 0.2);
                box-shadow: 0 0 0 2px rgba(255, 193, 7, 0.3);
            }
            .search-box::placeholder {
                color: rgba(255, 255, 255, 0.6);
            }
            table { 
                width: 100%; 
                border-collapse: collapse; 
                margin-top: 16px;
                table-layout: fixed;
            }
            th, td { 
                padding: 8px 16px; 
                text-align: left; 
                border: none;
                overflow: hidden;
            }
            th:first-child, td:first-child {
                width: 56px;
                min-width: 56px;
                max-width: 56px;
            }
            th:nth-child(2), td:nth-child(2) {
                width: auto;
                min-width: 0;
            }
            th:nth-child(3), td:nth-child(3) {
                width: 20%;
                min-width: 120px;
            }
            th:nth-child(4), td:nth-child(4) {
                width: 20%;
                min-width: 120px;
            }
            th:last-child, td:last-child {
                width: 200px;
                min-width: 200px;
                max-width: 200px;
            }
            th { 
                color: #b3b3b3; 
                font-weight: 400;
                font-size: 12px;
                text-transform: uppercase;
                letter-spacing: 1px;
                padding-bottom: 8px;
            }
            tbody tr {
                border-radius: 4px;
                transition: background 0.2s;
                position: relative;
            }
            tbody tr:hover { 
                background: rgba(255, 255, 255, 0.1); 
            }
            tbody tr:hover .play-pause-btn {
                opacity: 1 !important;
            }
            .play-pause-btn {
                font-size: 18px !important;
                width: 28px !important;
                height: 28px !important;
                min-width: 28px !important;
                min-height: 28px !important;
                display: flex !important;
                align-items: center !important;
                justify-content: center !important;
                font-family: Arial, "Helvetica Neue", Helvetica, sans-serif !important;
                font-variant-emoji: none !important;
                -webkit-font-feature-settings: "liga" off !important;
                font-feature-settings: "liga" off !important;
            }
            .play-pause-btn.paused {
                font-size: 20px !important;
            }
            tbody tr.playing {
                background: rgba(255, 193, 7, 0.15) !important;
            }
            tbody tr.playing:hover {
                background: rgba(255, 193, 7, 0.2) !important;
            }
            td {
                color: #fff;
                font-size: 14px;
                padding: 12px 16px;
            }
            td a { 
                color: #fff; 
                text-decoration: none; 
                font-weight: 400;
                transition: all 0.2s;
            }
            td a:hover { 
                color: #FFC107; 
                text-decoration: underline; 
            }
            .song-title-cell {
                min-width: 0;
                width: 100%;
                overflow: hidden;
            }
            .song-title {
                display: inline-block;
                max-width: 100%;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                flex: 1;
                min-width: 0;
            }
            /* Library-specific spacing */
            .library-view .song-title-cell {
                margin-left: -16px !important;
                gap: 6px !important;
            }
            .library-view td:first-child {
                padding-right: 4px;
            }
            .library-view td:nth-child(2) {
                padding-left: 4px;
            }
            td:nth-child(2) {
                overflow: hidden;
            }
            td:nth-child(3), td:nth-child(4) {
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .top-nav-mobile {
                display: none;
            }
            /* Playlists table specific - first column needs more width */
            .playlists-table th:first-child,
            .playlists-table td:first-child {
                width: auto !important;
                min-width: 200px !important;
                max-width: none !important;
            }
            /* Albums table specific - first column needs more width for header */
            .albums-table th:first-child,
            .albums-table td:first-child {
                width: auto !important;
                min-width: 200px !important;
                max-width: none !important;
            }
            /* Albums table specific - artist column needs more spacing */
            .albums-table th:nth-child(2),
            .albums-table td:nth-child(2) {
                padding-left: 48px !important;
            }
            .btn-download, .btn-delete, .btn-play {
                padding: 8px 16px;
                border: none;
                border-radius: 500px;
                cursor: pointer;
                font-size: 14px;
                font-weight: 700;
                transition: all 0.2s;
                text-decoration: none;
                display: inline-flex;
                align-items: center;
                gap: 8px;
            }
            .btn-download {
                background: transparent;
                color: #b3b3b3;
                border: 1px solid rgba(255, 255, 255, 0.3);
            }
            .btn-download:hover {
                background: rgba(255, 255, 255, 0.1);
                color: #fff;
                border-color: rgba(255, 255, 255, 0.5);
                transform: scale(1.05);
            }
            .btn-delete {
                background: transparent;
                color: #b3b3b3;
                border: 1px solid rgba(220, 53, 69, 0.3);
            }
            .btn-delete:hover {
                background: rgba(220, 53, 69, 0.1);
                color: #dc3545;
                border-color: rgba(220, 53, 69, 0.5);
                transform: scale(1.05);
            }
            .btn-play {
                background: #FFC107;
                color: #000;
                padding: 12px 32px;
                font-size: 14px;
            }
            .btn-play:hover {
                background: #FFD54F;
                transform: scale(1.05);
            }
            .stats {
                color: #b3b3b3;
                font-size: 14px;
                margin-bottom: 24px;
                font-weight: 400;
            }
            .album-header {
                background: transparent;
                font-weight: 600;
                padding-top: 24px;
                padding-bottom: 8px;
                color: #b3b3b3;
                font-size: 12px;
                text-transform: uppercase;
                letter-spacing: 1px;
            }
            .album-header:first-child {
                padding-top: 0;
            }
            .toast {
                position: fixed;
                top: 20px;
                right: 20px;
                background: #FFC107;
                color: #000;
                padding: 16px 24px;
                border-radius: 8px;
                box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
                z-index: 10000;
                font-weight: 500;
                animation: slideIn 0.3s ease-out;
                max-width: 400px;
            }
            @keyframes slideIn {
                from {
                    transform: translateX(100%);
                    opacity: 0;
                }
                to {
                    transform: translateX(0);
                    opacity: 1;
                }
            }
            .toast.success {
                background: #FFC107;
                color: #000;
            }
            .toast.error {
                background: #dc3545;
                color: #fff;
            }
            .btn-play {
                background: #28a745;
                color: white;
                padding: 6px 12px;
                border: none;
                border-radius: 6px;
                cursor: pointer;
                font-size: 14px;
                transition: all 0.2s;
                text-decoration: none;
                display: inline-block;
                margin-right: 5px;
            }
            .btn-play:hover {
                background: #218838;
                transform: translateY(-1px);
            }
            .audio-player {
                position: fixed;
                bottom: 0;
                left: 240px;
                right: 0;
                background: #181818;
                border-top: 1px solid rgba(255, 255, 255, 0.1);
                padding: 0;
                z-index: 9999;
                display: flex;
                align-items: center;
                height: 90px;
            }
            .player-left {
                display: flex;
                align-items: center;
                gap: 16px;
                padding: 0 16px;
                flex: 1;
                min-width: 0;
            }
            .player-artwork {
                width: 56px;
                height: 56px;
                border-radius: 4px;
                background: #333;
                object-fit: cover;
                flex-shrink: 0;
            }
            .player-info {
                min-width: 0;
                flex-shrink: 0;
                max-width: 200px;
            }
            .player-title {
                color: #fff;
                font-size: 14px;
                font-weight: 400;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                margin-bottom: 4px;
            }
            .player-artist {
                color: #b3b3b3;
                font-size: 11px;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
            }
            .player-center {
                display: flex;
                flex-direction: row;
                align-items: center;
                gap: 16px;
                flex: 1;
                padding: 0;
                min-width: 0;
            }
            .player-controls {
                display: flex;
                align-items: center;
                gap: 12px;
                flex-shrink: 0;
            }
            .player-control-btn {
                background: transparent;
                border: none;
                color: #fff;
                cursor: pointer;
                padding: 10px;
                display: flex;
                align-items: center;
                justify-content: center;
                transition: transform 0.2s;
                font-size: 20px;
                width: 40px;
                height: 40px;
                font-family: Arial, "Helvetica Neue", Helvetica, sans-serif !important;
                font-variant-emoji: none !important;
                -webkit-font-feature-settings: "liga" off !important;
                font-feature-settings: "liga" off !important;
            }
            .player-control-btn:hover {
                transform: scale(1.1);
            }
            .player-control-btn.play-pause {
                width: 48px;
                height: 48px;
                background: #fff;
                color: #000;
                border-radius: 50%;
                font-size: 20px;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            .player-control-btn.play-pause:hover {
                transform: scale(1.05);
            }
            .player-progress-container {
                flex: 1;
                display: flex;
                align-items: center;
                gap: 8px;
                min-width: 0;
            }
            .player-progress-bar {
                flex: 1;
                height: 4px;
                background: #535353;
                border-radius: 2px;
                cursor: pointer;
                position: relative;
            }
            .player-progress-fill {
                height: 100%;
                background: #FFC107;
                border-radius: 2px;
                transition: width 0.1s;
            }
            .player-time {
                color: #b3b3b3;
                font-size: 11px;
                min-width: 40px;
            }
            .player-right {
                display: flex;
                align-items: center;
                gap: 8px;
                padding: 0 16px 0 8px;
                flex-shrink: 0;
                justify-content: flex-end;
            }
            .player-menu {
                position: relative;
            }
            .player-menu-btn {
                background: transparent;
                border: none;
                color: #b3b3b3;
                cursor: pointer;
                padding: 8px;
                font-size: 18px;
                transition: color 0.2s;
            }
            .player-menu-btn:hover {
                color: #fff;
            }
            .player-menu-dropdown {
                position: absolute;
                bottom: 100%;
                right: 0;
                margin-bottom: 8px;
                background: #282828;
                border-radius: 4px;
                padding: 4px;
                min-width: 180px;
                box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5);
                display: none;
            }
            .player-menu-dropdown.show {
                display: block;
            }
            .player-menu-item {
                display: flex;
                align-items: center;
                gap: 12px;
                padding: 12px 16px;
                color: #fff;
                text-decoration: none;
                font-size: 14px;
                border-radius: 2px;
                cursor: pointer;
                transition: background 0.2s;
            }
            .player-menu-item:hover {
                background: rgba(255, 255, 255, 0.1);
            }
            .player-menu-item button {
                background: transparent;
                border: none;
                color: #fff;
                font-size: 14px;
                cursor: pointer;
                width: 100%;
                text-align: left;
                padding: 0;
            }
            /* Mobile Menu Toggle */
            .mobile-menu-toggle {
                display: none;
            }
            .sidebar-overlay {
                display: none;
                position: fixed;
                top: 0;
                left: 0;
                right: 0;
                bottom: 0;
                background: rgba(0, 0, 0, 0.7);
                z-index: 99;
            }
            .sidebar-overlay.show {
                display: block;
            }
            /* Mobile Responsive Styles */
            @media (max-width: 768px) {
                .sidebar {
                    display: none;
                }
                .sidebar-overlay {
                    display: none !important;
                }
                .main-content {
                    margin-left: 0;
                    width: 100%;
                }
                .container {
                    padding: 16px;
                }
                .top-bar {
                    padding: 12px 16px;
                    margin-left: 0;
                    margin-top: 8px;
                }
                h1 {
                    font-size: 24px;
                    margin-top: 50px;
                }
                .search-box {
                    max-width: 100%;
                    font-size: 16px;
                    padding: 14px 40px 14px 16px;
                }
                .top-nav-mobile {
                    margin-top: 12px;
                    display: flex;
                    flex-direction: row;
                    gap: 6px;
                    flex-wrap: wrap;
                }
                .top-nav-mobile a {
                    display: inline-block;
                    flex: 1;
                    min-width: 0;
                    padding: 10px 8px;
                    border-radius: 8px;
                    background: rgba(255, 255, 255, 0.04);
                    color: #FFC107;
                    text-decoration: none;
                    font-weight: 600;
                    font-size: 12px;
                    text-align: center;
                    white-space: nowrap;
                    overflow: visible;
                }
                .top-nav-mobile a:hover {
                    background: rgba(255, 193, 7, 0.15);
                    color: #FFC107;
                }
                /* Table adjustments for mobile */
                table {
                    display: block;
                    overflow-x: auto;
                    -webkit-overflow-scrolling: touch;
                    white-space: nowrap;
                }
                thead, tbody, tr {
                    display: table;
                    width: 100%;
                    table-layout: fixed;
                }
                th, td {
                    padding: 8px 12px;
                    font-size: 13px;
                }
                th {
                    font-size: 11px;
                    padding: 8px 12px;
                }
                /* Hide less important columns on mobile */
                th:nth-child(3),
                td:nth-child(3),
                th:nth-child(4),
                td:nth-child(4) {
                    display: none;
                }
                /* Make buttons touch-friendly */
                .btn-download, .btn-delete, .btn-play {
                    padding: 10px 16px;
                    font-size: 14px;
                    min-height: 44px;
                }
                .play-pause-btn {
                    width: 36px !important;
                    height: 36px !important;
                    min-width: 36px !important;
                    min-height: 36px !important;
                    font-size: 20px !important;
                    font-family: Arial, "Helvetica Neue", Helvetica, sans-serif !important;
                    font-variant-emoji: none !important;
                    -webkit-font-feature-settings: "liga" off !important;
                    font-feature-settings: "liga" off !important;
                    -webkit-font-smoothing: antialiased;
                    -moz-osx-font-smoothing: grayscale;
                }
                /* Audio player mobile layout */
                .audio-player {
                    left: 0;
                    height: auto;
                    flex-direction: row;
                    padding: 12px;
                    align-items: center;
                    gap: 12px;
                }
                .player-left {
                    display: flex;
                    align-items: center;
                    gap: 12px;
                    flex: 1;
                    min-width: 0;
                }
                .player-center {
                    display: flex;
                    flex-direction: row;
                    align-items: center;
                    gap: 8px;
                    flex-shrink: 0;
                }
                .player-controls {
                    display: flex;
                    align-items: center;
                    gap: 8px;
                }
                .player-progress-container {
                    display: none;
                }
                .player-right {
                    display: none;
                }
                .player-artwork {
                    width: 48px;
                    height: 48px;
                    flex-shrink: 0;
                }
                .player-info {
                    flex: 1;
                    min-width: 0;
                }
                .player-title {
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                }
                .player-artist {
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                }
                .player-control-btn {
                    font-family: Arial, "Helvetica Neue", Helvetica, sans-serif !important;
                    font-variant-emoji: none !important;
                    -webkit-font-feature-settings: "liga" off !important;
                    font-feature-settings: "liga" off !important;
                    -webkit-font-smoothing: antialiased;
                    -moz-osx-font-smoothing: grayscale;
                }
                .play-pause-btn {
                    font-family: Arial, "Helvetica Neue", Helvetica, sans-serif !important;
                    font-variant-emoji: none !important;
                    -webkit-font-feature-settings: "liga" off !important;
                    font-feature-settings: "liga" off !important;
                    -webkit-font-smoothing: antialiased;
                    -moz-osx-font-smoothing: grayscale;
                }
                /* Upload form mobile adjustments */
                .drag-drop-area {
                    padding: 40px 16px;
                }
                .drag-drop-area .icon {
                    font-size: 36px;
                }
                .drag-drop-area p {
                    font-size: 14px;
                }
                .file-input-label {
                    padding: 14px 24px;
                    font-size: 16px;
                    min-height: 44px;
                }
                button[type="submit"] {
                    padding: 16px 28px;
                    font-size: 16px;
                    min-height: 44px;
                }
                /* Toast adjustments */
                .toast {
                    top: 70px;
                    right: 16px;
                    left: 16px;
                    max-width: none;
                }
                /* Stats and other text */
                .stats {
                    font-size: 13px;
                }
                .nav a {
                    font-size: 16px;
                    padding: 14px 16px;
                    min-height: 44px;
                }
            }
            @media (max-width: 480px) {
                h1 {
                    font-size: 20px;
                }
                .container {
                    padding: 12px;
                }
                .top-bar {
                    padding: 10px 12px;
                }
                th, td {
                    padding: 6px 8px;
                    font-size: 12px;
                }
                /* Hide album column on very small screens */
                th:nth-child(4),
                td:nth-child(4) {
                    display: none;
                }
                .player-title {
                    font-size: 13px;
                }
                .player-artist {
                    font-size: 10px;
                }
                .player-control-btn {
                    width: 36px;
                    height: 36px;
                    font-size: 18px;
                }
                .player-control-btn.play-pause {
                    width: 44px;
                    height: 44px;
                }
            }
        </style>
        """
    }
    
    private func navigationBar() -> String {
        return """
        <button class="mobile-menu-toggle" id="mobileMenuToggle" onclick="toggleMobileMenu()">☰</button>
        <div class="sidebar-overlay" id="sidebarOverlay" onclick="closeMobileMenu()"></div>
        <div class="sidebar" id="sidebar">
            <div class="sidebar-logo">
                <h2>Zen</h2>
            </div>
            <div class="nav">
                <a href="/library" onclick="closeMobileMenu()">Library</a>
                <a href="/artists" onclick="closeMobileMenu()">Artists</a>
                <a href="/albums" onclick="closeMobileMenu()">Albums</a>
                <a href="/playlists" onclick="closeMobileMenu()">Playlists</a>
                <a href="/upload" onclick="closeMobileMenu()">Upload</a>
            </div>
        </div>
        """
    }
    
    private func mobileMenuScript() -> String {
        return """
        <script>
            function toggleMobileMenu() {
                const sidebar = document.getElementById('sidebar');
                const overlay = document.getElementById('sidebarOverlay');
                if (sidebar && overlay) {
                    sidebar.classList.toggle('open');
                    overlay.classList.toggle('show');
                }
            }
            function closeMobileMenu() {
                const sidebar = document.getElementById('sidebar');
                const overlay = document.getElementById('sidebarOverlay');
                if (sidebar && overlay) {
                    sidebar.classList.remove('open');
                    overlay.classList.remove('show');
                }
            }
            // Close menu when clicking outside on mobile
            document.addEventListener('click', function(event) {
                const sidebar = document.getElementById('sidebar');
                const overlay = document.getElementById('sidebarOverlay');
                const toggle = document.getElementById('mobileMenuToggle');
                if (sidebar && overlay && toggle) {
                    if (!sidebar.contains(event.target) && !toggle.contains(event.target) && sidebar.classList.contains('open')) {
                        closeMobileMenu();
                    }
                }
            });
        </script>
        """
    }
    
    private func songRowHTML(song: Song, index: Int, playlists: [Playlist], showPlaylistPicker: Bool = true, showDelete: Bool = true, playlistName: String? = nil, showAlbum: Bool = true, showArtwork: Bool = true) -> String {
        let encodedArtist = song.artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.artist
        let fileName = song.url.lastPathComponent
        let encodedFileName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let encodedAlbum = song.album.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.album
        let fileUrl = "/files/\(encodedFileName)"
        let encodedSongPath = song.url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.url.path
        let artworkUrl = "/artwork/\(encodedSongPath)"
        let hasArtwork = song.artworkContainer?.data != nil
        
        // Check if format is browser-supported
        let fileExt = song.url.pathExtension.lowercased()
        let isUnsupportedFormat = fileExt == "flac" || fileExt == "ogg"
        let formatWarning = isUnsupportedFormat ? " <span style=\"color: #ff9800; font-size: 11px; margin-left: 4px;\" title=\"This format may not play in browsers. Consider converting to MP3 or M4A.\">⚠</span>" : ""
        
        var actionsHTML = ""
        if showPlaylistPicker {
            actionsHTML += playlistPickerHTML(songUrl: song.url.path, playlists: playlists, songTitle: song.title)
        }
        actionsHTML += "<a href=\"\(fileUrl)\" download class=\"btn-download\" style=\"padding: 4px 8px; font-size: 12px;\">⬇</a>"
        
        if showDelete {
            if let playlistName = playlistName {
                actionsHTML += """
                <form method="POST" action="/playlist/remove-song" style="display: inline;">
                    <input type="hidden" name="playlistName" value="\(playlistName)">
                    <input type="hidden" name="songUrl" value="\(song.url.path)">
                    <button type="submit" onclick="return confirm('Remove \(song.title.escapedHTML()) from playlist?')" class="btn-delete" style="padding: 4px 8px; font-size: 12px;">➖</button>
                </form>
                """
            } else {
                actionsHTML += """
                <form method="POST" action="/delete" style="display: inline;">
                    <input type="hidden" name="url" value="\(song.url.path)">
                    <button type="submit" onclick="return confirm('Delete \(song.title.escapedHTML())?')" class="btn-delete" style="padding: 4px 8px; font-size: 12px;">🗑</button>
                </form>
                """
            }
        }
        
        let albumCell = showAlbum ? "<td><a href=\"/album/\(encodedAlbum)\">\(song.album)</a></td>" : ""
        
        // Escape for JavaScript strings (but keep original for display)
        let jsTitle = song.title.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\"", with: "\\\"")
        let jsArtist = song.artist.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\"", with: "\\\"")
        
        // Artwork HTML for first column (only if showArtwork is true)
        let artworkHTML: String
        if showArtwork {
            artworkHTML = hasArtwork ? """
                <img src="\(artworkUrl)" alt="Album artwork" style="width: 40px; height: 40px; object-fit: cover; border-radius: 4px; margin-right: 8px;">
            """ : """
                <div style="width: 40px; height: 40px; background: #333; border-radius: 4px; margin-right: 8px; display: flex; align-items: center; justify-content: center; color: #666; font-size: 20px;">♪</div>
            """
        } else {
            artworkHTML = ""
        }
        
        let firstColumnWidth = showArtwork ? "56px" : "40px"
        let firstColumnContent = showArtwork ? """
            \(artworkHTML)
        """ : """
            ""
        """
        
        return """
        <tr data-song-url="\(fileUrl)" data-song-title="\(jsTitle)" data-song-artist="\(jsArtist)" data-song-artwork="\(hasArtwork ? artworkUrl : "")" data-song-path="\(encodedSongPath)">
            <td style="width: \(firstColumnWidth);">
                <div style="display: flex; align-items: center;">
                    \(firstColumnContent)
                </div>
            </td>
            <td>
                <div class="song-title-cell" style="display: flex; align-items: center; gap: 12px;">
                    <button onclick="togglePlayPause('\(fileUrl)', '\(jsTitle)', '\(jsArtist)', '\(hasArtwork ? artworkUrl : "")', '\(encodedSongPath)')" class="play-pause-btn" style="background: transparent; border: none; color: #fff; cursor: pointer; opacity: 0; transition: opacity 0.2s; padding: 6px; font-size: 18px; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; font-family: Arial, 'Helvetica Neue', Helvetica, sans-serif;">►</button>
                    <span class="song-title">\(song.title.escapedHTML())\(formatWarning)</span>
                </div>
            </td>
            \(showAlbum ? "<td><a href=\"/artist/\(encodedArtist)\">\(song.artist.escapedHTML())</a></td>" : "<td>\(song.album.escapedHTML())</td>")
            \(albumCell)
            <td style="text-align: right;">
                <div style="display: flex; align-items: center; gap: 8px; justify-content: flex-end;">
                    \(actionsHTML)
                </div>
            </td>
        </tr>
        """
    }
    
    private func playlistPickerHTML(songUrl: String, playlists: [Playlist], songTitle: String = "") -> String {
        if playlists.isEmpty {
            return "<span style=\"color: #888; font-size: 12px;\">No playlists</span>"
        }
        
        let options = playlists.map { playlist in
            let encodedName = playlist.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlist.name
            return "<option value=\"\(encodedName)\">\(playlist.name.escapedHTML())</option>"
        }.joined(separator: "\n")
        
        let encodedSongUrl = songUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? songUrl
        let encodedTitle = songTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? songTitle
        
        return """
        <form class="add-to-playlist-form" data-song-url="\(encodedSongUrl)" data-song-title="\(encodedTitle)" style="display: inline;">
            <select name="playlistName" style="padding: 4px 8px; background: rgba(255, 255, 255, 0.1); border: 1px solid rgba(255, 255, 255, 0.2); border-radius: 500px; color: #fff; font-size: 12px; margin-right: 4px; outline: none;">
                <option value="">Add to...</option>
                \(options)
            </select>
            <button type="submit" style="display: none;"></button>
        </form>
        <script>
            (function() {
                const form = document.currentScript.previousElementSibling;
                const select = form.querySelector('select[name="playlistName"]');
                select.addEventListener('change', async function(e) {
                    const playlistName = select.value;
                    if (!playlistName) return;
                    
                    const songUrl = form.dataset.songUrl;
                    const songTitle = form.dataset.songTitle || 'Song';
                    
                    try {
                        const formData = new URLSearchParams();
                        formData.append('playlistName', playlistName);
                        formData.append('songUrl', songUrl);
                        formData.append('ajax', 'true');
                        
                        const response = await fetch('/playlist/add-song', {
                            method: 'POST',
                            headers: {
                                'Content-Type': 'application/x-www-form-urlencoded',
                            },
                            body: formData.toString()
                        });
                        
                        if (response.ok) {
                            const result = await response.json();
                            if (result.success) {
                                showToast('Added to ' + playlistName, 'success');
                                select.value = ''; // Reset selection
                            } else {
                                showToast(result.error || 'Failed to add song', 'error');
                            }
                        } else {
                            showToast('Failed to add song', 'error');
                        }
                    } catch (error) {
                        showToast('Error: ' + error.message, 'error');
                    }
                });
            })();
        </script>
        """
    }
    
    private func searchBar(placeholder: String = "Search songs, artists, albums...") -> String {
        return """
        <div class="search-container">
            <form method="GET" action="/library" style="display: flex; align-items: center; gap: 8px; width: 100%;" onsubmit="return handleSearch(event);">
                <input type="text" 
                       id="searchBox" 
                       name="search"
                       class="search-box" 
                       placeholder="\(placeholder)" 
                       value=""
                       autocomplete="off"
                       style="flex: 1;">
                <button type="submit" style="display: none;"></button>
            </form>
            <div class="top-nav-mobile">
                <a href="/library">Library</a>
                <a href="/artists">Artists</a>
                <a href="/albums">Albums</a>
                <a href="/playlists">Playlists</a>
                <a href="/upload">Upload</a>
            </div>
        </div>
        <script>
            function handleSearch(event) {
                const input = document.getElementById('searchBox');
                const searchValue = input.value.trim();
                if (searchValue) {
                    const encoded = encodeURIComponent(searchValue);
                    window.location.href = '/library?search=' + encoded;
                } else {
                    window.location.href = '/library';
                }
                event.preventDefault();
                return false;
            }
            function showToast(message, type = 'success') {
                const toast = document.createElement('div');
                toast.className = 'toast ' + type;
                toast.textContent = message;
                document.body.appendChild(toast);
                
                setTimeout(() => {
                    toast.style.animation = 'slideIn 0.3s ease-out reverse';
                    setTimeout(() => toast.remove(), 300);
                }, 3000);
            }
            
            let currentAudio = null;
            let currentSongUrl = null;
            let currentSongData = null;
            
            function formatTime(seconds) {
                const mins = Math.floor(seconds / 60);
                const secs = Math.floor(seconds % 60);
                return mins + ':' + (secs < 10 ? '0' : '') + secs;
            }
            
            function togglePlayPause(songUrl, songTitle, songArtist, artworkUrl, songPath) {
                // If same song, toggle play/pause
                if (currentSongUrl === songUrl && currentAudio) {
                    if (currentAudio.paused) {
                        currentAudio.play();
                        updatePlayButton(songUrl, false);
                    } else {
                        currentAudio.pause();
                        updatePlayButton(songUrl, true);
                    }
                    return;
                }
                
                // Stop current audio if different song
                if (currentAudio) {
                    currentAudio.pause();
                    currentAudio = null;
                }
                
                // Remove playing class from all rows
                document.querySelectorAll('tr.playing').forEach(row => {
                    row.classList.remove('playing');
                    const btn = row.querySelector('.play-pause-btn');
                    if (btn) {
                        btn.textContent = '►';
                        btn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                        btn.classList.remove('paused');
                    }
                });
                
                // Play new song
                playSong(songUrl, songTitle, songArtist, artworkUrl, songPath);
            }
            
            function playSong(songUrl, songTitle, songArtist, artworkUrl, songPath) {
                currentSongUrl = songUrl;
                // Decode URL-encoded values if needed
                const decodedTitle = decodeURIComponent(songTitle.replace(/\\+/g, ' '));
                const decodedArtist = decodeURIComponent(songArtist.replace(/\\+/g, ' '));
                currentSongData = { title: decodedTitle, artist: decodedArtist, artworkUrl: artworkUrl, path: songPath };
                
                // Remove existing player if any
                const existingPlayer = document.getElementById('global-audio-player');
                if (existingPlayer) {
                    existingPlayer.remove();
                }
                
                // Create audio element
                const audio = document.createElement('audio');
                audio.src = songUrl;
                audio.autoplay = true;
                currentAudio = audio;
                
                // Add error handling
                audio.addEventListener('error', (e) => {
                    let errorMsg = 'Unable to play this song. ';
                    if (audio.error) {
                        switch(audio.error.code) {
                            case audio.error.MEDIA_ERR_ABORTED:
                                errorMsg += 'Playback was aborted.';
                                break;
                            case audio.error.MEDIA_ERR_NETWORK:
                                errorMsg += 'A network error occurred.';
                                break;
                            case audio.error.MEDIA_ERR_DECODE:
                                errorMsg += 'The audio file is corrupted or in an unsupported format.';
                                break;
                            case audio.error.MEDIA_ERR_SRC_NOT_SUPPORTED:
                                const fileExt = songUrl.split('.').pop()?.toLowerCase();
                                if (fileExt === 'flac') {
                                    errorMsg += 'FLAC format is not supported by browsers. Please convert to MP3 or M4A.';
                                } else if (fileExt === 'ogg') {
                                    errorMsg += 'OGG format may not be supported by your browser. Try MP3 or M4A.';
                                } else {
                                    errorMsg += 'The audio format is not supported by your browser. Supported formats: MP3, M4A, WAV, AAC.';
                                }
                                break;
                            default:
                                errorMsg += 'An unknown error occurred (Code: ' + audio.error.code + ').';
                        }
                    } else {
                        errorMsg += 'The file may be corrupted or in an unsupported format.';
                    }
                    showToast(errorMsg, 'error');
                    console.error('Audio error:', audio.error);
                    
                    // Remove playing state
                    document.querySelectorAll('tr.playing').forEach(row => {
                        row.classList.remove('playing');
                        const btn = row.querySelector('.play-pause-btn');
                        if (btn) {
                            btn.textContent = '►';
                        btn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                            btn.classList.remove('paused');
                        }
                    });
                    currentSongUrl = null;
                    currentAudio = null;
                });
                
                // Update progress bar
                audio.addEventListener('timeupdate', () => {
                    if (audio.duration) {
                        const progress = (audio.currentTime / audio.duration) * 100;
                        const progressFill = document.querySelector('.player-progress-fill');
                        const currentTimeEl = document.querySelector('.player-time-current');
                        const durationEl = document.querySelector('.player-time-duration');
                        if (progressFill) progressFill.style.width = progress + '%';
                        if (currentTimeEl) currentTimeEl.textContent = formatTime(audio.currentTime);
                        if (durationEl) durationEl.textContent = formatTime(audio.duration);
                    }
                });
                
                audio.addEventListener('loadedmetadata', () => {
                    const durationEl = document.querySelector('.player-time-duration');
                    if (durationEl) durationEl.textContent = formatTime(audio.duration);
                });
                
                audio.addEventListener('ended', () => {
                    // Remove playing state when song ends
                    document.querySelectorAll('tr.playing').forEach(row => {
                        row.classList.remove('playing');
                        const btn = row.querySelector('.play-pause-btn');
                        if (btn) {
                            btn.textContent = '►';
                        btn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                            btn.classList.remove('paused');
                        }
                    });
                    currentSongUrl = null;
                    currentAudio = null;
                });
                
                // Create player bar
                const playerDiv = document.createElement('div');
                playerDiv.id = 'global-audio-player';
                playerDiv.className = 'audio-player';
                playerDiv.innerHTML = `
                    <div class="player-left">
                        <img src="${artworkUrl || 'data:image/svg+xml,<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"56\" height=\"56\"><rect width=\"56\" height=\"56\" fill=\"%23333\"/><text x=\"50%\" y=\"50%\" text-anchor=\"middle\" dy=\".3em\" fill=\"%23999\" font-size=\"24\">♪</text></svg>'}" 
                             alt="Artwork" 
                             class="player-artwork"
                             onerror="this.src='data:image/svg+xml,<svg xmlns=\\'http://www.w3.org/2000/svg\\' width=\\'56\\' height=\\'56\\'><rect width=\\'56\\' height=\\'56\\' fill=\\'%23333\\'/><text x=\\'50%\\' y=\\'50%\\' text-anchor=\\'middle\\' dy=\\'.3em\\' fill=\\'%23999\\' font-size=\\'24\\'>♪</text></svg>'">
                        <div class="player-info">
                            <div class="player-title">${decodedTitle}</div>
                            <div class="player-artist">${decodedArtist}</div>
                        </div>
                        <div class="player-controls">
                            <button class="player-control-btn" onclick="previousSong()" title="Previous" style="font-family: Arial, 'Helvetica Neue', Helvetica, sans-serif;">◄◄</button>
                            <button class="player-control-btn play-pause" id="player-play-pause-btn" onclick="toggleCurrentPlayPause()" title="Play/Pause" style="font-family: Arial, 'Helvetica Neue', Helvetica, sans-serif;">||</button>
                            <button class="player-control-btn" onclick="nextSong()" title="Next" style="font-family: Arial, 'Helvetica Neue', Helvetica, sans-serif;">►►</button>
                        </div>
                        <div class="player-progress-container">
                            <span class="player-time player-time-current">0:00</span>
                            <div class="player-progress-bar" onclick="seekTo(event)">
                                <div class="player-progress-fill" style="width: 0%"></div>
                            </div>
                            <span class="player-time player-time-duration">0:00</span>
                        </div>
                        <div class="player-menu">
                            <button class="player-menu-btn" onclick="togglePlayerMenu()">⋯</button>
                            <div class="player-menu-dropdown" id="player-menu">
                                <a href="${songUrl}" download class="player-menu-item">⬇ Download</a>
                                <div class="player-menu-item" onclick="addCurrentSongToPlaylist(); togglePlayerMenu();">➕ Add to Playlist</div>
                                <form method="POST" action="/delete" style="display: contents;" onsubmit="return confirm('Delete this song?')">
                                    <input type="hidden" name="url" value="${songPath}">
                                    <button type="submit" class="player-menu-item" style="color: #dc3545;">🗑 Delete</button>
                                </form>
                            </div>
                        </div>
                    </div>
                `;
                document.body.appendChild(playerDiv);
                
                // Hide default audio controls and add to player
                audio.style.display = 'none';
                playerDiv.appendChild(audio);
                
                // Mark row as playing
                updatePlayingRow(songUrl, false);
                
                // Update play button to pause
                updatePlayButton(songUrl, false);
                
                // Update player bar play/pause button
                const playPauseBtn = document.getElementById('player-play-pause-btn');
                if (playPauseBtn) {
                    playPauseBtn.textContent = '||';
                    playPauseBtn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                    playPauseBtn.style.fontSize = '22px';
                }
                
                // Update when audio starts playing
                audio.addEventListener('play', () => {
                    updatePlayButton(songUrl, false);
                    updatePlayingRow(songUrl, false);
                    const btn = document.getElementById('player-play-pause-btn');
                    if (btn) {
                        btn.textContent = '||';
                        btn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                        btn.style.fontSize = '22px';
                    }
                });
                
                // Update when audio pauses
                audio.addEventListener('pause', () => {
                    updatePlayButton(songUrl, true);
                    updatePlayingRow(songUrl, true);
                    const btn = document.getElementById('player-play-pause-btn');
                    if (btn) {
                        btn.textContent = '►';
                        btn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                        btn.style.fontSize = '20px';
                    }
                });
            }
            
            function updatePlayingRow(songUrl, isPaused) {
                document.querySelectorAll('tr[data-song-url]').forEach(row => {
                    if (row.getAttribute('data-song-url') === songUrl) {
                        if (!isPaused) {
                            row.classList.add('playing');
                        } else {
                            row.classList.remove('playing');
                        }
                    } else {
                        row.classList.remove('playing');
                    }
                });
            }
            
            function updatePlayButton(songUrl, isPaused) {
                document.querySelectorAll('tr[data-song-url]').forEach(row => {
                    if (row.getAttribute('data-song-url') === songUrl) {
                        const btn = row.querySelector('.play-pause-btn');
                        if (btn) {
                            btn.textContent = isPaused ? '►' : '||';
                            btn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                        btn.style.fontVariantEmoji = 'none';
                        btn.style.webkitFontFeatureSettings = "'liga' off";
                        btn.style.fontFeatureSettings = "'liga' off";
                            if (isPaused) {
                                btn.classList.remove('paused');
                            } else {
                                btn.classList.add('paused');
                            }
                        }
                    } else {
                        const btn = row.querySelector('.play-pause-btn');
                        if (btn) {
                            btn.textContent = '►';
                        btn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                            btn.classList.remove('paused');
                        }
                    }
                });
            }
            
            function toggleCurrentPlayPause() {
                if (currentAudio) {
                    const playPauseBtn = document.getElementById('player-play-pause-btn');
                    if (currentAudio.paused) {
                        currentAudio.play();
                        updatePlayButton(currentSongUrl, false);
                        updatePlayingRow(currentSongUrl, false);
                        if (playPauseBtn) {
                            playPauseBtn.textContent = '||';
                            playPauseBtn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                            playPauseBtn.style.fontSize = '22px';
                        }
                    } else {
                        currentAudio.pause();
                        updatePlayButton(currentSongUrl, true);
                        updatePlayingRow(currentSongUrl, true);
                        if (playPauseBtn) {
                            playPauseBtn.textContent = '►';
                            playPauseBtn.style.fontFamily = "Arial, 'Helvetica Neue', Helvetica, sans-serif";
                            playPauseBtn.style.fontSize = '20px';
                        }
                    }
                }
            }
            
            function previousSong() {
                if (!currentSongUrl) return;
                
                // Find all song rows in the current table
                const allRows = Array.from(document.querySelectorAll('tr[data-song-url]'));
                if (allRows.length === 0) return;
                
                // Find the current song's index
                const currentIndex = allRows.findIndex(row => row.getAttribute('data-song-url') === currentSongUrl);
                if (currentIndex === -1) return;
                
                // Get the previous song (wrap around to end if at beginning)
                const previousIndex = currentIndex > 0 ? currentIndex - 1 : allRows.length - 1;
                const previousRow = allRows[previousIndex];
                
                // Extract song data from the row
                const songUrl = previousRow.getAttribute('data-song-url');
                const songTitle = previousRow.getAttribute('data-song-title');
                const songArtist = previousRow.getAttribute('data-song-artist');
                const songArtwork = previousRow.getAttribute('data-song-artwork') || '';
                
                // Find the song path from the row's play button
                const playButton = previousRow.querySelector('.play-pause-btn');
                if (playButton) {
                    // Extract the song path from the onclick handler
                    const onclickStr = playButton.getAttribute('onclick') || '';
                    // Match the last parameter (songPath) in togglePlayPause call
                    const pathMatch = onclickStr.match(/togglePlayPause\\([^)]+,'([^']+)'\\)/);
                    const songPath = pathMatch ? pathMatch[1] : '';
                    
                    // Decode the title and artist for display
                    const decodedTitle = decodeURIComponent(songTitle.replace(/\\+/g, ' '));
                    const decodedArtist = decodeURIComponent(songArtist.replace(/\\+/g, ' '));
                    
                    // Play the previous song
                    playSong(songUrl, decodedTitle, decodedArtist, songArtwork, songPath);
                }
            }
            
            function nextSong() {
                if (!currentSongUrl) return;
                
                // Find all song rows in the current table
                const allRows = Array.from(document.querySelectorAll('tr[data-song-url]'));
                if (allRows.length === 0) return;
                
                // Find the current song's index
                const currentIndex = allRows.findIndex(row => row.getAttribute('data-song-url') === currentSongUrl);
                if (currentIndex === -1) return;
                
                // Get the next song (wrap around to beginning if at end)
                const nextIndex = currentIndex < allRows.length - 1 ? currentIndex + 1 : 0;
                const nextRow = allRows[nextIndex];
                
                // Extract song data from the row
                const songUrl = nextRow.getAttribute('data-song-url');
                const songTitle = nextRow.getAttribute('data-song-title');
                const songArtist = nextRow.getAttribute('data-song-artist');
                const songArtwork = nextRow.getAttribute('data-song-artwork') || '';
                
                // Find the song path from the row's play button
                const playButton = nextRow.querySelector('.play-pause-btn');
                if (playButton) {
                    // Extract the song path from the onclick handler
                    const onclickStr = playButton.getAttribute('onclick') || '';
                    // Match the last parameter (songPath) in togglePlayPause call
                    const pathMatch = onclickStr.match(/togglePlayPause\\([^)]+,'([^']+)'\\)/);
                    const songPath = pathMatch ? pathMatch[1] : '';
                    
                    // Decode the title and artist for display
                    const decodedTitle = decodeURIComponent(songTitle.replace(/\\+/g, ' '));
                    const decodedArtist = decodeURIComponent(songArtist.replace(/\\+/g, ' '));
                    
                    // Play the next song
                    playSong(songUrl, decodedTitle, decodedArtist, songArtwork, songPath);
                }
            }
            
            function seekTo(event) {
                if (!currentAudio) return;
                const progressBar = event.currentTarget;
                const rect = progressBar.getBoundingClientRect();
                const x = event.clientX - rect.left;
                const percent = x / rect.width;
                currentAudio.currentTime = percent * currentAudio.duration;
            }
            
            function togglePlayerMenu() {
                const menu = document.getElementById('player-menu');
                if (menu) {
                    menu.classList.toggle('show');
                }
            }
            
            function addCurrentSongToPlaylist() {
                if (!currentSongData) return;
                
                // Get all playlists from the page (from any playlist picker dropdown)
                // Use a Map to ensure uniqueness by value
                const playlistMap = new Map();
                document.querySelectorAll('select[name="playlistName"] option').forEach(option => {
                    if (option.value && !playlistMap.has(option.value)) {
                        playlistMap.set(option.value, option.textContent);
                    }
                });
                const playlists = Array.from(playlistMap.entries()).map(([value, name]) => ({
                    value: value,
                    name: name
                }));
                
                if (playlists.length === 0) {
                    showToast('No playlists available', 'error');
                    return;
                }
                
                // Create playlist picker
                const picker = document.createElement('div');
                picker.id = 'playlist-picker-overlay';
                picker.style.cssText = 'position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.7); z-index: 10001; display: flex; align-items: center; justify-content: center;';
                picker.innerHTML = `
                    <div style="background: #282828; padding: 24px; border-radius: 8px; max-width: 400px; width: 90%;">
                        <h3 style="color: #fff; margin-bottom: 16px;">Add to Playlist</h3>
                        <select id="playlist-picker-select" style="width: 100%; padding: 12px; background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.2); border-radius: 4px; color: #fff; font-size: 14px; margin-bottom: 16px;">
                            <option value="">Select playlist...</option>
                            ${playlists.map(p => `<option value="${p.value}">${p.name}</option>`).join('')}
                        </select>
                        <div style="display: flex; gap: 8px; justify-content: flex-end;">
                            <button onclick="document.getElementById('playlist-picker-overlay').remove()" style="padding: 8px 16px; background: transparent; border: 1px solid rgba(255,255,255,0.3); color: #fff; border-radius: 4px; cursor: pointer;">Cancel</button>
                            <button onclick="confirmAddToPlaylist()" style="padding: 8px 16px; background: #FFC107; color: #000; border: none; border-radius: 4px; cursor: pointer; font-weight: 600;">Add</button>
                        </div>
                    </div>
                `;
                // Close on overlay click
                picker.addEventListener('click', function(e) {
                    if (e.target === picker) {
                        picker.remove();
                    }
                });
                document.body.appendChild(picker);
                
                window.confirmAddToPlaylist = async function() {
                    const select = document.getElementById('playlist-picker-select');
                    const playlistName = select.value;
                    if (!playlistName) {
                        showToast('Please select a playlist', 'error');
                        return;
                    }
                    
                    if (!currentSongData || !currentSongData.path) {
                        showToast('No song selected', 'error');
                        return;
                    }
                    
                    try {
                        const formData = new URLSearchParams();
                        formData.append('playlistName', decodeURIComponent(playlistName));
                        formData.append('songUrl', currentSongData.path);
                        formData.append('ajax', 'true');
                        
                        const response = await fetch('/playlist/add-song', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                            body: formData.toString()
                        });
                        
                        if (response.ok) {
                            const result = await response.json();
                            if (result.success) {
                                showToast('Added to ' + playlists.find(p => p.value === playlistName)?.name, 'success');
                                picker.remove();
                            } else {
                                showToast(result.error || 'Failed to add song', 'error');
                            }
                        } else {
                            const errorText = await response.text();
                            console.error('Add to playlist error:', errorText);
                            showToast('Failed to add song', 'error');
                        }
                    } catch (error) {
                        console.error('Add to playlist error:', error);
                        showToast('Error: ' + error.message, 'error');
                    }
                };
            }
            
            // Close menu when clicking outside
            document.addEventListener('click', (e) => {
                const menu = document.getElementById('player-menu');
                if (menu && !e.target.closest('.player-menu')) {
                    menu.classList.remove('show');
                }
            });
            
            // Set search box value from URL if present
            (function() {
                const urlParams = new URLSearchParams(window.location.search);
                const searchParam = urlParams.get('search');
                if (searchParam) {
                    const searchBox = document.getElementById('searchBox');
                    if (searchBox) {
                        searchBox.value = decodeURIComponent(searchParam);
                    }
                }
            })();
        </script>
        """
    }
    
    // MARK: - Library Views
    
    private func libraryView(container: ModelContainer, searchQuery: String = "", page: Int = 1) -> HTTPResponse {
        let context = ModelContext(container)
        let songDescriptor = FetchDescriptor<Song>(sortBy: [SortDescriptor(\.title)])
        let playlistDescriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.name)])
        
        guard let allSongs = try? context.fetch(songDescriptor),
              let playlists = try? context.fetch(playlistDescriptor) else {
            return HTTPResponse(.internalServerError, content: "Could not fetch songs or playlists")
        }
        
        // Filter songs based on search query
        let filteredSongs: [Song]
        if !searchQuery.isEmpty {
            let queryLower = searchQuery.lowercased()
            filteredSongs = allSongs.filter { song in
                song.title.lowercased().contains(queryLower) ||
                song.artist.lowercased().contains(queryLower) ||
                song.album.lowercased().contains(queryLower)
            }
        } else {
            filteredSongs = allSongs
        }
        
        // Pagination: show 100 songs per page
        let pageSize = 100
        let totalSongs = filteredSongs.count
        let totalPages = max(1, (totalSongs + pageSize - 1) / pageSize)
        let currentPage = max(1, min(page, totalPages))
        let startIndex = (currentPage - 1) * pageSize
        let endIndex = min(startIndex + pageSize, totalSongs)
        let songs = Array(filteredSongs[startIndex..<endIndex])
        
        let songsHTML = songs.enumerated().map { index, song in
            songRowHTML(song: song, index: startIndex + index, playlists: playlists)
        }.joined(separator: "\n")
        
        // Calculate alphabet page mapping (for navigation)
        var letterPageMap: [String: Int] = [:]
        if searchQuery.isEmpty {
            // Find the first occurrence of each letter and calculate which page it's on
            for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
                let letterStr = String(letter)
                if let firstIndex = filteredSongs.firstIndex(where: { 
                    let firstChar = String($0.title.prefix(1)).uppercased()
                    return firstChar == letterStr && firstChar.rangeOfCharacter(from: .letters) != nil
                }) {
                    let page = (firstIndex / pageSize) + 1
                    letterPageMap[letterStr] = page
                }
            }
        }
        
        // Generate alphabet navigation
        var alphabetHTML = ""
        if searchQuery.isEmpty && totalPages > 1 {
            let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }
            alphabetHTML = "<div style=\"margin-bottom: 16px; display: flex; align-items: center; justify-content: center; gap: 4px; flex-wrap: wrap; padding: 12px; background: rgba(255,255,255,0.03); border-radius: 8px;\">"
            for letter in alphabet {
                if let targetPage = letterPageMap[letter] {
                    alphabetHTML += "<a href=\"/library?page=\(targetPage)\" style=\"padding: 6px 10px; background: rgba(255,255,255,0.1); color: #FFC107; text-decoration: none; border-radius: 4px; font-weight: 600; font-size: 14px; min-width: 32px; text-align: center; transition: all 0.2s;\" onmouseover=\"this.style.background='rgba(255,193,7,0.2)'\" onmouseout=\"this.style.background='rgba(255,255,255,0.1)'\">\(letter)</a>"
                } else {
                    alphabetHTML += "<span style=\"padding: 6px 10px; color: rgba(255,255,255,0.2); font-size: 14px; min-width: 32px; text-align: center;\">\(letter)</span>"
                }
            }
            alphabetHTML += "</div>"
        }
        
        // Generate pagination controls
        var paginationHTML = ""
        if totalPages > 1 {
            let searchParam = searchQuery.isEmpty ? "" : "&search=\(searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery)"
            paginationHTML = "<div style=\"margin-top: 24px; display: flex; align-items: center; justify-content: center; gap: 8px; flex-wrap: wrap;\">"
            if currentPage > 1 {
                paginationHTML += "<a href=\"/library?page=\(currentPage - 1)\(searchParam)\" style=\"padding: 8px 16px; background: rgba(255,255,255,0.1); color: #FFC107; text-decoration: none; border-radius: 4px; font-weight: 600;\">← Previous</a>"
            }
            paginationHTML += "<span style=\"color: #b3b3b3; padding: 8px 16px;\">Page \(currentPage) of \(totalPages)</span>"
            if currentPage < totalPages {
                paginationHTML += "<a href=\"/library?page=\(currentPage + 1)\(searchParam)\" style=\"padding: 8px 16px; background: rgba(255,255,255,0.1); color: #FFC107; text-decoration: none; border-radius: 4px; font-weight: 600;\">Next →</a>"
            }
            paginationHTML += "</div>"
        }
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Library - Zen</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(faviconLink())
            \(commonCSS())
        </head>
        <body>
            <div class="app-container">
                \(navigationBar())
                <div class="main-content">
                    <div class="top-bar">
                        \(searchBar())
                    </div>
                    <div class="container library-view">
                        <h1>Your Library</h1>
                        <div class="stats">\(totalSongs) song\(totalSongs == 1 ? "" : "s")\(totalPages > 1 ? " (showing \(startIndex + 1)-\(endIndex))" : "")\(!searchQuery.isEmpty ? " - Search: \"\(searchQuery)\" <a href=\"/library\" style=\"color: #FFC107; text-decoration: none; margin-left: 8px;\">[Clear]</a>" : "")</div>
                        \(alphabetHTML)
                        <table>
                            <thead>
                                <tr>
                                    <th>#</th>
                                    <th>Title</th>
                                    <th>Artist</th>
                                    <th>Album</th>
                                    <th></th>
                                </tr>
                            </thead>
                            <tbody>
                                \(songsHTML)
                            </tbody>
                        </table>
                        \(paginationHTML)
                    </div>
                </div>
            </div>
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        let _ = { response = response }()
        return response
    }
    
    private func artistsView(container: ModelContainer) -> HTTPResponse {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Song>()
        
        guard let songs = try? context.fetch(descriptor) else {
            return HTTPResponse(.internalServerError, content: "Could not fetch songs")
        }
        
        // Group by artist
        let artists = Dictionary(grouping: songs) { song in
            // Extract primary artist (before comma or feat/ft)
            let artist = song.artist
            if let commaIndex = artist.firstIndex(of: ",") {
                return String(artist[..<commaIndex]).trimmingCharacters(in: .whitespaces)
            }
            if let featIndex = artist.range(of: " feat", options: .caseInsensitive)?.lowerBound {
                return String(artist[..<featIndex]).trimmingCharacters(in: .whitespaces)
            }
            if let ftIndex = artist.range(of: " ft", options: .caseInsensitive)?.lowerBound {
                return String(artist[..<ftIndex]).trimmingCharacters(in: .whitespaces)
            }
            return artist
        }
        
        let sortedArtists = artists.keys.sorted()
        let artistsHTML = sortedArtists.map { artist in
            let count = artists[artist]?.count ?? 0
            let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artist
            return """
            <tr onclick="window.location.href='/artist/\(encodedArtist)'" style="cursor: pointer;">
                <td>\(artist)</td>
                <td style="text-align: right;">\(count) song\(count == 1 ? "" : "s")</td>
            </tr>
            """
        }.joined(separator: "\n")
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Artists - Zen</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(faviconLink())
            \(commonCSS())
        </head>
        <body>
            <div class="app-container">
                \(navigationBar())
                <div class="main-content">
                    <div class="top-bar">
                        \(searchBar(placeholder: "Search artists..."))
                    </div>
                    <div class="container">
                        <h1>Artists</h1>
                        <div class="stats">\(sortedArtists.count) artists</div>
                        <table>
                            <thead>
                                <tr>
                                    <th>Artist</th>
                                    <th style="text-align: right;">Songs</th>
                                </tr>
                            </thead>
                            <tbody>
                                \(artistsHTML)
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
            \(mobileMenuScript())
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        let _ = { response = response }()
        return response
    }
    
    private func artistDetailView(container: ModelContainer, artist: String) -> HTTPResponse {
        let context = ModelContext(container)
        let songDescriptor = FetchDescriptor<Song>()
        let playlistDescriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.name)])
        
        guard let allSongs = try? context.fetch(songDescriptor),
              let playlists = try? context.fetch(playlistDescriptor) else {
            return HTTPResponse(.internalServerError, content: "Could not fetch songs or playlists")
        }
        
        // Filter songs by artist (matching primary artist)
        let artistSongs = allSongs.filter { song in
            let songArtist = song.artist
            let primaryArtist: String
            if let commaIndex = songArtist.firstIndex(of: ",") {
                primaryArtist = String(songArtist[..<commaIndex]).trimmingCharacters(in: .whitespaces)
            } else if let featIndex = songArtist.range(of: " feat", options: .caseInsensitive)?.lowerBound {
                primaryArtist = String(songArtist[..<featIndex]).trimmingCharacters(in: .whitespaces)
            } else if let ftIndex = songArtist.range(of: " ft", options: .caseInsensitive)?.lowerBound {
                primaryArtist = String(songArtist[..<ftIndex]).trimmingCharacters(in: .whitespaces)
            } else {
                primaryArtist = songArtist
            }
            return primaryArtist == artist
        }.sorted { $0.title < $1.title }
        
        // Group by album
        let byAlbum = Dictionary(grouping: artistSongs) { $0.album }
        let sortedAlbums = byAlbum.keys.sorted()
        
        var songsHTML = ""
        var songIndex = 1
        for album in sortedAlbums {
            // Get artwork from first song in album
            let firstSong = byAlbum[album]?.first
            let hasArtwork = firstSong?.artworkContainer?.data != nil
            let artworkUrl = hasArtwork ? "/artwork/\(firstSong!.url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? firstSong!.url.path)" : ""
            let artworkHTML = hasArtwork ? """
                <img src="\(artworkUrl)" alt="Album artwork" style="width: 56px; height: 56px; object-fit: cover; border-radius: 4px; margin-right: 12px;">
            """ : """
                <div style="width: 56px; height: 56px; background: #333; border-radius: 4px; margin-right: 12px; display: flex; align-items: center; justify-content: center; color: #666; font-size: 24px;">♪</div>
            """
            songsHTML += """
            <tr class="album-header">
                <td colspan="4">
                    <div style="display: flex; align-items: center;">
                        \(artworkHTML)
                        <span style="font-weight: 600; font-size: 16px;">\(album.escapedHTML())</span>
                    </div>
                </td>
            </tr>
            """
            for song in byAlbum[album] ?? [] {
                songsHTML += songRowHTML(song: song, index: songIndex - 1, playlists: playlists, showAlbum: false, showArtwork: false)
                songIndex += 1
            }
        }
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>\(artist) - Zen</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(faviconLink())
            \(commonCSS())
        </head>
        <body>
            <div class="app-container">
                \(navigationBar())
                <div class="main-content">
                    <div class="top-bar">
                        \(searchBar(placeholder: "Search songs in \(artist)..."))
                    </div>
                    <div class="container">
                        <h1>\(artist)</h1>
                        <div class="stats">\(artistSongs.count) songs</div>
                        <table>
                            <thead>
                                <tr>
                                    <th>#</th>
                                    <th>Title</th>
                                    <th>Album</th>
                                    <th></th>
                                </tr>
                            </thead>
                            <tbody>
                                \(songsHTML)
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
            \(mobileMenuScript())
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        let _ = { response = response }()
        return response
    }
    
    private func albumsView(container: ModelContainer) -> HTTPResponse {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Song>()
        
        guard let songs = try? context.fetch(descriptor) else {
            return HTTPResponse(.internalServerError, content: "Could not fetch songs")
        }
        
        // Group by album
        let albums = Dictionary(grouping: songs) { $0.album }
        let sortedAlbums = albums.keys.sorted()
        
        let albumsHTML = sortedAlbums.map { album in
            let count = albums[album]?.count ?? 0
            let artist = albums[album]?.first?.artist ?? "Unknown"
            let encodedAlbum = album.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? album
            // Get artwork from first song in album
            let firstSong = albums[album]?.first
            let hasArtwork = firstSong?.artworkContainer?.data != nil
            let artworkUrl = hasArtwork ? "/artwork/\(firstSong!.url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? firstSong!.url.path)" : ""
            let artworkHTML = hasArtwork ? """
                <img src="\(artworkUrl)" alt="Album artwork" style="width: 56px; height: 56px; object-fit: cover; border-radius: 4px; margin-right: 12px;">
            """ : """
                <div style="width: 56px; height: 56px; background: #333; border-radius: 4px; margin-right: 12px; display: flex; align-items: center; justify-content: center; color: #666; font-size: 24px;">♪</div>
            """
            return """
            <tr onclick="window.location.href='/album/\(encodedAlbum)'" style="cursor: pointer;">
                <td>
                    <div style="display: flex; align-items: center;">
                        \(artworkHTML)
                        <span>\(album.escapedHTML())</span>
                    </div>
                </td>
                <td>\(artist.escapedHTML())</td>
                <td>\(count) song\(count == 1 ? "" : "s")</td>
            </tr>
            """
        }.joined(separator: "\n")
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Albums - Zen</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(faviconLink())
            \(commonCSS())
        </head>
        <body>
            <div class="app-container">
                \(navigationBar())
                <div class="main-content">
                    <div class="top-bar">
                        \(searchBar(placeholder: "Search albums..."))
                    </div>
                    <div class="container">
                        <h1>Albums</h1>
                        <div class="stats">\(sortedAlbums.count) albums</div>
                        <table class="albums-table">
                            <thead>
                                <tr>
                                    <th>Album</th>
                                    <th>Artist</th>
                                    <th>Songs</th>
                                </tr>
                            </thead>
                            <tbody>
                                \(albumsHTML)
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        let _ = { response = response }()
        return response
    }
    
    private func albumDetailView(container: ModelContainer, album: String) -> HTTPResponse {
        let context = ModelContext(container)
        let songDescriptor = FetchDescriptor<Song>()
        let playlistDescriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.name)])
        
        guard let allSongs = try? context.fetch(songDescriptor),
              let playlists = try? context.fetch(playlistDescriptor) else {
            return HTTPResponse(.internalServerError, content: "Could not fetch songs or playlists")
        }
        
        let albumSongs = allSongs.filter { $0.album == album }.sorted { $0.title < $1.title }
        let artist = albumSongs.first?.artist ?? "Unknown"
        
        let songsHTML = albumSongs.enumerated().map { index, song in
            songRowHTML(song: song, index: index, playlists: playlists)
        }.joined(separator: "\n")
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>\(album) - Zen</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(faviconLink())
            \(commonCSS())
        </head>
        <body>
            <div class="app-container">
                \(navigationBar())
                <div class="main-content">
                    <div class="top-bar">
                        \(searchBar(placeholder: "Search songs in \(album)..."))
                    </div>
                    <div class="container">
                        <h1>\(album)</h1>
                        <div class="stats">by \(artist) • \(albumSongs.count) songs</div>
                        <table>
                            <thead>
                                <tr>
                                    <th>#</th>
                                    <th>Title</th>
                                    <th>Artist</th>
                                    <th></th>
                                </tr>
                            </thead>
                            <tbody>
                                \(songsHTML)
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
            \(mobileMenuScript())
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        let _ = { response = response }()
        return response
    }
    
    private func playlistsView(container: ModelContainer) -> HTTPResponse {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.name)])
        
        guard let playlists = try? context.fetch(descriptor) else {
            return HTTPResponse(.internalServerError, content: "Could not fetch playlists")
        }
        
        let playlistsHTML = playlists.map { playlist in
            let count = playlist.songs?.count ?? 0
            let encodedName = playlist.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlist.name
            return """
            <tr>
                <td onclick="window.location.href='/playlist/\(encodedName)'" style="cursor: pointer;">\(playlist.name)</td>
                <td onclick="window.location.href='/playlist/\(encodedName)'" style="cursor: pointer; text-align: right;">\(count) song\(count == 1 ? "" : "s")</td>
                <td onclick="event.stopPropagation();">
                    <a href="/playlist/\(encodedName)/edit" class="btn-download" style="padding: 6px 12px; font-size: 12px;">✏️ Edit</a>
                    <form method="POST" action="/playlist/delete" style="display: inline; margin-left: 5px;">
                        <input type="hidden" name="playlistName" value="\(playlist.name)">
                        <button type="submit" onclick="return confirm('Delete playlist \\'\(playlist.name.escapedHTML())\\''?')" class="btn-delete" style="padding: 6px 12px; font-size: 12px;">🗑️ Delete</button>
                    </form>
                </td>
            </tr>
            """
        }.joined(separator: "\n")
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Playlists - Zen</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(faviconLink())
            \(commonCSS())
            <style>
                .create-playlist-form {
                    margin-bottom: 25px;
                    padding: 20px;
                    background: rgba(255, 193, 7, 0.1);
                    border: 1px solid rgba(255, 193, 7, 0.3);
                    border-radius: 8px;
                }
                .create-playlist-form input {
                    padding: 10px 15px;
                    background: rgba(255, 255, 255, 0.1);
                    border: 1px solid rgba(255, 255, 255, 0.2);
                    border-radius: 6px;
                    color: #fff;
                    font-size: 16px;
                    width: 300px;
                    margin-right: 10px;
                }
                .create-playlist-form input:focus {
                    outline: none;
                    border-color: #FFC107;
                    background: rgba(255, 255, 255, 0.15);
                }
                .create-playlist-form button {
                    padding: 10px 20px;
                    background: #FFC107;
                    color: #000;
                    border: none;
                    border-radius: 6px;
                    font-weight: 600;
                    cursor: pointer;
                }
                .create-playlist-form button:hover {
                    background: #FFB300;
                }
            </style>
        </head>
        <body>
            <div class="app-container">
                \(navigationBar())
                <div class="main-content">
                    <div class="top-bar">
                        \(searchBar(placeholder: "Search playlists..."))
                    </div>
                    <div class="container">
                        <h1>Playlists</h1>
                        <div class="stats">\(playlists.count) playlists</div>
                        <div class="create-playlist-form">
                            <form method="POST" action="/playlist/create" style="display: flex; align-items: center;">
                                <input type="text" name="playlistName" placeholder="New playlist name" required autocomplete="off">
                                <button type="submit">➕ Create Playlist</button>
                            </form>
                        </div>
                        <table class="playlists-table">
                            <thead>
                                <tr>
                                    <th>Playlist</th>
                                    <th style="text-align: right;">Songs</th>
                                    <th></th>
                                </tr>
                            </thead>
                            <tbody>
                                \(playlistsHTML)
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
            \(mobileMenuScript())
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        let _ = { response = response }()
        return response
    }
    
    private func playlistDetailView(container: ModelContainer, playlistName: String) -> HTTPResponse {
        let context = ModelContext(container)
        let playlistDescriptor = FetchDescriptor<Playlist>()
        
        guard let playlists = try? context.fetch(playlistDescriptor) else {
            return HTTPResponse(.notFound, content: "Could not fetch playlists")
        }
        
        // Debug: Print all playlist names to help diagnose matching issues
        #if DEBUG
        print("🔍 Detail view - Looking for playlist: '\(playlistName)'")
        print("🔍 Detail view - Available playlists: \(playlists.map { $0.name })")
        #endif
        
        guard let playlist = playlists.first(where: { $0.name == playlistName }) else {
            // Try case-insensitive match as fallback
            if let caseInsensitiveMatch = playlists.first(where: { $0.name.lowercased() == playlistName.lowercased() }) {
                #if DEBUG
                print("⚠️ Found case-insensitive match, using: '\(caseInsensitiveMatch.name)'")
                #endif
                return playlistDetailView(container: container, playlistName: caseInsensitiveMatch.name)
            }
            return HTTPResponse(.notFound, content: "Playlist '\(playlistName)' not found. Available: \(playlists.map { $0.name }.joined(separator: ", "))")
        }
        
        guard let songs = playlist.songs else {
            return HTTPResponse(.notFound, content: "Playlist has no songs")
        }
        
        let sortedSongs = songs.sorted { $0.title < $1.title }
        let encodedPlaylistName = playlistName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistName
        let songsHTML = sortedSongs.enumerated().map { index, song in
            songRowHTML(song: song, index: index, playlists: [], showPlaylistPicker: false, showDelete: true, playlistName: playlistName)
        }.joined(separator: "\n")
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>\(playlistName) - Zen</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(faviconLink())
            \(commonCSS())
            <style>
                .playlist-actions {
                    margin-bottom: 20px;
                    display: flex;
                    gap: 10px;
                    flex-wrap: wrap;
                }
                .playlist-actions a, .playlist-actions form {
                    display: inline-block;
                }
            </style>
        </head>
        <body>
            <div class="app-container">
                \(navigationBar())
                <div class="main-content">
                    <div class="top-bar">
                        \(searchBar(placeholder: "Search songs in \(playlistName)..."))
                    </div>
                    <div class="container">
                        <h1>\(playlistName)</h1>
                        <div class="stats">\(sortedSongs.count) songs</div>
                        <div class="playlist-actions">
                            <a href="/playlist/\(encodedPlaylistName)/edit" class="btn-download">✏️ Edit / Add Songs</a>
                            <form method="POST" action="/playlist/delete" style="display: inline;">
                                <input type="hidden" name="playlistName" value="\(playlistName)">
                                <button type="submit" onclick="return confirm('Delete playlist \\'\(playlistName.escapedHTML())\\''?')" class="btn-delete">🗑️ Delete Playlist</button>
                            </form>
                        </div>
                        <table>
                            <thead>
                                <tr>
                                    <th>#</th>
                                    <th>Title</th>
                                    <th>Artist</th>
                                    <th>Album</th>
                                    <th></th>
                                </tr>
                            </thead>
                            <tbody>
                                \(songsHTML)
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
            \(mobileMenuScript())
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        let _ = { response = response }()
        return response
    }
    
    private func handleDelete(container: ModelContainer, request: HTTPRequest) -> HTTPResponse {
        let context = ModelContext(container)
        
        // Parse form data - handle both application/x-www-form-urlencoded
        guard let bodyString = String(data: request.body, encoding: .utf8) else {
            return HTTPResponse(.badRequest, content: "Invalid request")
        }
        
        var urlString = ""
        if bodyString.contains("url=") {
            // Parse URL from form data
            let components = bodyString.components(separatedBy: "&")
            for component in components {
                if component.hasPrefix("url=") {
                    urlString = String(component.dropFirst(4))
                        .replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? ""
                    break
                }
            }
        } else {
            // Try to parse as direct path
            urlString = bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        guard !urlString.isEmpty else {
            return HTTPResponse(.badRequest, content: "No file path provided")
        }
        
        // Create file URL from path
        let fileURL: URL
        if urlString.hasPrefix("file://") {
            fileURL = URL(string: urlString) ?? URL(fileURLWithPath: String(urlString.dropFirst(7)))
        } else {
            fileURL = URL(fileURLWithPath: urlString)
        }
        
        // Find and delete the song from database
        let descriptor = FetchDescriptor<Song>()
        if let songs = try? context.fetch(descriptor),
           let song = songs.first(where: { $0.url.path == fileURL.path }) {
            // Delete from database (this will cascade delete artwork)
            context.delete(song)
            try? context.save()
        }
        
        // Delete the file if it exists
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        // Redirect back to library
        return redirectResponse(to: "/library")
    }
    
    private func redirectResponse(to path: String) -> HTTPResponse {
        // Note: Setting headers does mutate the response, but compiler may not detect it
        var response = HTTPResponse(.seeOther)
        response.headers["Location"] = path
        // Force mutation detection by reassigning
        let _ = { response = response }()
        return response
    }
    
    // MARK: - Playlist Management Handlers
    
    private func handleCreatePlaylist(container: ModelContainer, request: HTTPRequest) -> HTTPResponse {
        let context = ModelContext(container)
        
        guard let bodyString = String(data: request.body, encoding: .utf8) else {
            return HTTPResponse(.badRequest, content: "Invalid request")
        }
        
        // Parse form data
        var playlistName = ""
        if bodyString.contains("playlistName=") {
            let components = bodyString.components(separatedBy: "&")
            for component in components {
                if component.hasPrefix("playlistName=") {
                    playlistName = String(component.dropFirst(13))
                        .replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? ""
                    break
                }
            }
        }
        
        guard !playlistName.isEmpty else {
            return HTTPResponse(.badRequest, content: "Playlist name required")
        }
        
        // Check if playlist already exists
        let descriptor = FetchDescriptor<Playlist>()
        if let existingPlaylists = try? context.fetch(descriptor),
           existingPlaylists.contains(where: { $0.name == playlistName }) {
            return redirectResponse(to: "/playlists?error=Playlist already exists")
        }
        
        // Create new playlist
        let newPlaylist = Playlist(name: playlistName.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(newPlaylist)
        try? context.save()
        
        return redirectResponse(to: "/playlists")
    }
    
    private func handleDeletePlaylist(container: ModelContainer, request: HTTPRequest) -> HTTPResponse {
        let context = ModelContext(container)
        
        guard let bodyString = String(data: request.body, encoding: .utf8) else {
            return HTTPResponse(.badRequest, content: "Invalid request")
        }
        
        // Parse form data
        var playlistName = ""
        if bodyString.contains("playlistName=") {
            let components = bodyString.components(separatedBy: "&")
            for component in components {
                if component.hasPrefix("playlistName=") {
                    playlistName = String(component.dropFirst(13))
                        .replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? ""
                    break
                }
            }
        }
        
        guard !playlistName.isEmpty else {
            return HTTPResponse(.badRequest, content: "Playlist name required")
        }
        
        // Find and delete playlist
        let descriptor = FetchDescriptor<Playlist>()
        if let playlists = try? context.fetch(descriptor),
           let playlist = playlists.first(where: { $0.name == playlistName }) {
            context.delete(playlist)
            try? context.save()
        }
        
        return redirectResponse(to: "/playlists")
    }
    
    private func handleRenamePlaylist(container: ModelContainer, request: HTTPRequest) -> HTTPResponse {
        let context = ModelContext(container)
        
        guard let bodyString = String(data: request.body, encoding: .utf8) else {
            return HTTPResponse(.badRequest, content: "Invalid request")
        }
        
        // Parse form data
        var oldName = ""
        var newName = ""
        let components = bodyString.components(separatedBy: "&")
        for component in components {
            if component.hasPrefix("oldName=") {
                oldName = String(component.dropFirst(8))
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? ""
            } else if component.hasPrefix("newName=") {
                newName = String(component.dropFirst(8))
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? ""
            }
        }
        
        guard !oldName.isEmpty && !newName.isEmpty else {
            return HTTPResponse(.badRequest, content: "Playlist names required")
        }
        
        // Find and rename playlist
        let descriptor = FetchDescriptor<Playlist>()
        if let playlists = try? context.fetch(descriptor),
           let playlist = playlists.first(where: { $0.name == oldName }) {
            playlist.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            try? context.save()
            let encodedNewName = newName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? newName
            return redirectResponse(to: "/playlist/\(encodedNewName)")
        }
        
        return redirectResponse(to: "/playlists")
    }
    
    private func handleAddSongToPlaylist(container: ModelContainer, request: HTTPRequest) -> HTTPResponse {
        let context = ModelContext(container)
        
        guard let bodyString = String(data: request.body, encoding: .utf8) else {
            return HTTPResponse(.badRequest, content: "Invalid request")
        }
        
        // Parse form data
        var playlistName = ""
        var songUrlPath = ""
        var isAjax = false
        let components = bodyString.components(separatedBy: "&")
        for component in components {
            if component.hasPrefix("playlistName=") {
                playlistName = String(component.dropFirst(13))
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? ""
            } else if component.hasPrefix("songUrl=") {
                songUrlPath = String(component.dropFirst(8))
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? ""
            } else if component.hasPrefix("ajax=") {
                isAjax = true
            }
        }
        
        guard !playlistName.isEmpty && !songUrlPath.isEmpty else {
            if isAjax {
                let json = """
                {"success": false, "error": "Please select a playlist"}
                """
                var response = HTTPResponse(.badRequest)
                response.body = json.data(using: .utf8) ?? Data()
                response.headers["Content-Type"] = "application/json"
                let _ = { response = response }()
                return response
            }
            return redirectResponse(to: "/library?error=Please select a playlist")
        }
        
        // Find playlist and song
        let playlistDescriptor = FetchDescriptor<Playlist>()
        let songDescriptor = FetchDescriptor<Song>()
        
        // Decode the path (it might be URL-encoded)
        let decodedPath = songUrlPath.removingPercentEncoding ?? songUrlPath
        // Normalize the path for comparison (remove leading/trailing slashes)
        let normalizedPath = decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        if let playlists = try? context.fetch(playlistDescriptor),
           let playlist = playlists.first(where: { $0.name == playlistName }),
           let songs = try? context.fetch(songDescriptor) {
            
            // Try exact match first (both encoded and decoded)
            var song = songs.first(where: { 
                $0.url.path == songUrlPath || $0.url.path == decodedPath
            })
            
            // If no exact match, try normalized path comparison
            if song == nil {
                song = songs.first(where: { 
                    let songPath = $0.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return songPath == normalizedPath || 
                           $0.url.path.hasSuffix(normalizedPath) || 
                           normalizedPath.hasSuffix(songPath) ||
                           $0.url.path == decodedPath
                })
            }
            
            // If still no match, try by filename
            if song == nil {
                let fileName = URL(fileURLWithPath: decodedPath).lastPathComponent
                song = songs.first(where: { $0.url.lastPathComponent == fileName })
            }
            
            // Last resort: try matching by Documents directory path
            if song == nil {
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
                let fullPath = documentsPath + "/" + normalizedPath
                song = songs.first(where: { $0.url.path == fullPath || $0.url.path.hasSuffix(normalizedPath) })
            }
            
            if let song = song {
                // Add song to playlist if not already there
                if playlist.songs == nil {
                    playlist.songs = []
                }
                let alreadyAdded = playlist.songs?.contains(where: { $0.id == song.id }) ?? false
                if !alreadyAdded {
                    playlist.songs?.append(song)
                    appendSongToPlaylistOrder(playlist: playlist, song: song)
                    recordHistory(context: context, action: "added_to_playlist", songTitle: song.title, songArtist: song.artist, playlistName: playlist.name)
                    try? context.save()
                }
                
                if isAjax {
                    let json = """
                    {"success": true, "message": "Added to \(playlistName)"}
                    """
                    var response = HTTPResponse(.ok)
                    response.body = json.data(using: .utf8) ?? Data()
                    response.headers["Content-Type"] = "application/json"
                    let _ = { response = response }()
                    return response
                }
                
                let encodedName = playlistName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistName
                return redirectResponse(to: "/playlist/\(encodedName)")
            }
        }
        
        // Log error details for debugging
        #if DEBUG
        print("⚠️ Add to playlist failed - playlistName: '\(playlistName)', songUrlPath: '\(songUrlPath)'")
        if let playlists = try? context.fetch(playlistDescriptor) {
            print("Available playlists: \(playlists.map { $0.name })")
        }
        if let songs = try? context.fetch(songDescriptor) {
            print("Available songs (first 5 paths): \(songs.prefix(5).map { $0.url.path })")
        }
        #endif
        
        if isAjax {
            let json = """
            {"success": false, "error": "Playlist or song not found. Path: \(songUrlPath)"}
            """
            var response = HTTPResponse(.notFound)
            response.body = json.data(using: .utf8) ?? Data()
            response.headers["Content-Type"] = "application/json"
            let _ = { response = response }()
            return response
        }
        
        return redirectResponse(to: "/playlists")
    }
    
    private func handleRemoveSongFromPlaylist(container: ModelContainer, request: HTTPRequest) -> HTTPResponse {
        let context = ModelContext(container)
        
        guard let bodyString = String(data: request.body, encoding: .utf8) else {
            return HTTPResponse(.badRequest, content: "Invalid request")
        }
        
        // Parse form data
        var playlistName = ""
        var songUrlPath = ""
        let components = bodyString.components(separatedBy: "&")
        for component in components {
            if component.hasPrefix("playlistName=") {
                playlistName = String(component.dropFirst(13))
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? ""
            } else if component.hasPrefix("songUrl=") {
                songUrlPath = String(component.dropFirst(8))
                    .replacingOccurrences(of: "+", with: " ")
                    .removingPercentEncoding ?? ""
            }
        }
        
        guard !playlistName.isEmpty && !songUrlPath.isEmpty else {
            return HTTPResponse(.badRequest, content: "Playlist name and song URL required")
        }
        
        // Find playlist and remove song
        let playlistDescriptor = FetchDescriptor<Playlist>()
        if let playlists = try? context.fetch(playlistDescriptor),
           let playlist = playlists.first(where: { $0.name == playlistName }) {
            
            if let index = playlist.songs?.firstIndex(where: { $0.url.path == songUrlPath }),
               let song = playlist.songs?[index] {
                removeSongFromPlaylistOrder(playlist: playlist, song: song)
                recordHistory(context: context, action: "removed_from_playlist", songTitle: song.title, songArtist: song.artist, playlistName: playlist.name)
                playlist.songs?.remove(at: index)
                try? context.save()
            }
            
            let encodedName = playlistName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistName
            return redirectResponse(to: "/playlist/\(encodedName)")
        }
        
        return redirectResponse(to: "/playlists")
    }
    
    private func playlistEditView(container: ModelContainer, playlistName: String) -> HTTPResponse {
        let context = ModelContext(container)
        let playlistDescriptor = FetchDescriptor<Playlist>()
        let songDescriptor = FetchDescriptor<Song>(sortBy: [SortDescriptor(\.title)])
        
        guard let playlists = try? context.fetch(playlistDescriptor),
              let allSongs = try? context.fetch(songDescriptor) else {
            return HTTPResponse(.notFound, content: "Could not fetch playlists or songs")
        }
        
        // Debug: Print all playlist names to help diagnose matching issues
        #if DEBUG
        print("🔍 Looking for playlist: '\(playlistName)'")
        print("🔍 Available playlists: \(playlists.map { $0.name })")
        #endif
        
        guard let playlist = playlists.first(where: { $0.name == playlistName }) else {
            // Try case-insensitive match as fallback
            if let caseInsensitiveMatch = playlists.first(where: { $0.name.lowercased() == playlistName.lowercased() }) {
                #if DEBUG
                print("⚠️ Found case-insensitive match, using: '\(caseInsensitiveMatch.name)'")
                #endif
                return playlistEditView(container: container, playlistName: caseInsensitiveMatch.name)
            }
            let errorHTML = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>Playlist Not Found - Zen</title>
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                \(faviconLink())
                \(commonCSS())
            </head>
            <body>
                <div class="container">
                    \(navigationBar())
                    <h1>❌ Playlist Not Found</h1>
                    <p>Could not find playlist: <strong>\(playlistName.escapedHTML())</strong></p>
                    <p>Available playlists:</p>
                    <ul>
                        \(playlists.map { "<li><a href=\"/playlist/\($0.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0.name)/edit\">\($0.name.escapedHTML())</a></li>" }.joined(separator: "\n"))
                    </ul>
                    <a href="/playlists" class="btn-download">← Back to Playlists</a>
                </div>
            </body>
            </html>
            """
            let htmlData = errorHTML.data(using: .utf8) ?? Data()
            var response = HTTPResponse(.notFound)
            response.body = htmlData
            response.headers["Content-Type"] = "text/html; charset=utf-8"
            let _ = { response = response }()
            return response
        }
        
        let playlistSongs = playlist.songs ?? []
        let playlistSongIds = Set(playlistSongs.map { $0.id })
        
        // Separate songs into in-playlist and not-in-playlist
        let inPlaylist = allSongs.filter { playlistSongIds.contains($0.id) }.sorted { $0.title < $1.title }
        let notInPlaylist = allSongs.filter { !playlistSongIds.contains($0.id) }.sorted { $0.title < $1.title }
        
        let inPlaylistHTML = inPlaylist.map { song in
            let encodedArtist = song.artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.artist
            let encodedAlbum = song.album.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.album
            return """
            <tr>
                <td>\(song.title)</td>
                <td><a href="/artist/\(encodedArtist)">\(song.artist)</a></td>
                <td><a href="/album/\(encodedAlbum)">\(song.album)</a></td>
                <td>
                    <form method="POST" action="/playlist/remove-song" style="display: inline;">
                        <input type="hidden" name="playlistName" value="\(playlistName)">
                        <input type="hidden" name="songUrl" value="\(song.url.path)">
                        <button type="submit" class="btn-delete" style="padding: 6px 12px; font-size: 12px;">➖ Remove</button>
                    </form>
                </td>
            </tr>
            """
        }.joined(separator: "\n")
        
        let notInPlaylistHTML = notInPlaylist.map { song in
            let encodedArtist = song.artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.artist
            let encodedAlbum = song.album.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.album
            return """
            <tr>
                <td>\(song.title)</td>
                <td><a href="/artist/\(encodedArtist)">\(song.artist)</a></td>
                <td><a href="/album/\(encodedAlbum)">\(song.album)</a></td>
                <td>
                    <form method="POST" action="/playlist/add-song" style="display: inline;">
                        <input type="hidden" name="playlistName" value="\(playlistName)">
                        <input type="hidden" name="songUrl" value="\(song.url.path)">
                        <button type="submit" class="btn-download" style="padding: 6px 12px; font-size: 12px;">➕ Add</button>
                    </form>
                </td>
            </tr>
            """
        }.joined(separator: "\n")
        
        let encodedPlaylistName = playlistName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistName
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Edit \(playlistName) - Zen</title>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \(faviconLink())
            \(commonCSS())
            <style>
                .rename-form {
                    margin-bottom: 25px;
                    padding: 20px;
                    background: rgba(255, 193, 7, 0.1);
                    border: 1px solid rgba(255, 193, 7, 0.3);
                    border-radius: 8px;
                }
                .rename-form input {
                    padding: 10px 15px;
                    background: rgba(255, 255, 255, 0.1);
                    border: 1px solid rgba(255, 255, 255, 0.2);
                    border-radius: 6px;
                    color: #fff;
                    font-size: 16px;
                    width: 300px;
                    margin-right: 10px;
                }
                .rename-form input:focus {
                    outline: none;
                    border-color: #FFC107;
                    background: rgba(255, 255, 255, 0.15);
                }
                .rename-form button {
                    padding: 10px 20px;
                    background: #FFC107;
                    color: #000;
                    border: none;
                    border-radius: 6px;
                    font-weight: 600;
                    cursor: pointer;
                }
                .rename-form button:hover {
                    background: #FFB300;
                }
                .section-header {
                    margin-top: 30px;
                    margin-bottom: 15px;
                    font-size: 18px;
                    font-weight: 600;
                    color: #FFC107;
                }
            </style>
        </head>
        <body>
            <div class="container">
                \(navigationBar())
                <h1>✏️ Edit Playlist: \(playlistName)</h1>
                <div class="rename-form">
                    <form method="POST" action="/playlist/rename" style="display: flex; align-items: center;">
                        <input type="hidden" name="oldName" value="\(playlistName)">
                        <input type="text" name="newName" value="\(playlistName)" required autocomplete="off">
                        <button type="submit">💾 Rename</button>
                    </form>
                </div>
                <div class="section-header">Songs in Playlist (\(inPlaylist.count))</div>
                <div class="search-container">
                    <input type="text" 
                           id="searchBox1" 
                           class="search-box" 
                           placeholder="Search songs in playlist..." 
                           onkeyup="filterTable('table1')"
                           autocomplete="off">
                </div>
                <table id="table1">
                    <thead>
                        <tr>
                            <th>Title</th>
                            <th>Artist</th>
                            <th>Album</th>
                            <th>Action</th>
                        </tr>
                    </thead>
                    <tbody>
                        \(inPlaylistHTML)
                    </tbody>
                </table>
                <div class="section-header">All Songs - Add to Playlist (\(notInPlaylist.count))</div>
                <div class="search-container">
                    <input type="text" 
                           id="searchBox2" 
                           class="search-box" 
                           placeholder="Search all songs to add..." 
                           onkeyup="filterTable('table2')"
                           autocomplete="off">
                </div>
                <table id="table2">
                    <thead>
                        <tr>
                            <th>Title</th>
                            <th>Artist</th>
                            <th>Album</th>
                            <th>Action</th>
                        </tr>
                    </thead>
                    <tbody>
                        \(notInPlaylistHTML)
                    </tbody>
                </table>
                <script>
                    function filterTable(tableId) {
                        const input = document.getElementById(tableId === 'table1' ? 'searchBox1' : 'searchBox2');
                        const filter = input.value.toLowerCase();
                        const table = document.getElementById(tableId);
                        if (!table) return;
                        
                        const tbody = table.querySelector('tbody');
                        if (!tbody) return;
                        const rows = tbody.getElementsByTagName('tr');
                        let visibleCount = 0;
                        
                        for (let i = 0; i < rows.length; i++) {
                            const row = rows[i];
                            const text = row.textContent.toLowerCase();
                            if (text.includes(filter)) {
                                row.style.display = '';
                                visibleCount++;
                            } else {
                                row.style.display = 'none';
                            }
                        }
                    }
                </script>
                <div style="margin-top: 30px;">
                    <a href="/playlist/\(encodedPlaylistName)" class="btn-download">← Back to Playlist</a>
                </div>
            </div>
            \(mobileMenuScript())
        </body>
        </html>
        """
        let htmlData = html.data(using: .utf8) ?? Data()
        var response = HTTPResponse(.ok)
        response.body = htmlData
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        let _ = { response = response }()
        return response
    }
}

// Helper extension for HTML escaping
extension String {
    func escapedHTML() -> String {
        return self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
