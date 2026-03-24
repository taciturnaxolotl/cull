import Foundation

/// Reads and writes XMP sidecar files for photo metadata interoperability.
/// Uses `<basename>.xmp` naming (Lightroom/Bridge compatible).
struct XMPSidecar {

    /// Metadata stored in an XMP sidecar
    struct Metadata {
        var rating: Int = 0   // 0 = unrated, 1-5 = stars, -1 = rejected
        var label: String?    // color label: "Red", "Yellow", "Green", "Blue", "Purple"
    }

    /// Returns the XMP sidecar URL for a given photo URL
    static func sidecarURL(for photoURL: URL) -> URL {
        photoURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: - Read

    /// Read metadata from an existing XMP sidecar, if present
    static func read(for photoURL: URL) -> Metadata? {
        let url = sidecarURL(for: photoURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let doc = try? XMLDocument(contentsOf: url, options: []) else { return nil }

        var meta = Metadata()

        // Try attribute form: xmp:Rating="3" on rdf:Description
        if let ratingStr = try? doc.nodes(forXPath: "//@xmp:Rating").first?.stringValue,
           let rating = Int(ratingStr) {
            meta.rating = rating
        }
        // Try element form: <xmp:Rating>3</xmp:Rating>
        else if let ratingStr = try? doc.nodes(forXPath: "//xmp:Rating").first?.stringValue,
                let rating = Int(ratingStr) {
            meta.rating = rating
        }

        if let label = try? doc.nodes(forXPath: "//@xmp:Label").first?.stringValue {
            meta.label = label
        } else if let label = try? doc.nodes(forXPath: "//xmp:Label").first?.stringValue {
            meta.label = label
        }

        return meta
    }

    // MARK: - Write

    /// Write metadata to an XMP sidecar, merging with existing content if present
    static func write(_ photo: Photo) {
        let url = sidecarURL(for: photo.url)
        let xmpRating = xmpRating(for: photo)

        // If an existing XMP exists, try to merge
        if FileManager.default.fileExists(atPath: url.path),
           let doc = try? XMLDocument(contentsOf: url, options: [.nodePreserveWhitespace]) {
            if mergeInto(doc, rating: xmpRating) {
                try? doc.xmlData(options: [.nodePrettyPrint]).write(to: url)
                return
            }
        }

        // Write fresh XMP
        let xml = freshXMP(rating: xmpRating)
        try? xml.data(using: .utf8)?.write(to: url)
    }

    // MARK: - Mapping

    /// Map Cull's rating/flag to XMP rating value
    private static func xmpRating(for photo: Photo) -> Int {
        if photo.flag == .reject { return -1 }
        return photo.rating  // 0 = unrated, 1-5 = stars
    }

    /// Map XMP metadata back to Cull's rating/flag
    static func apply(_ meta: Metadata, to photo: Photo) {
        if meta.rating == -1 {
            photo.flag = .reject
        } else if meta.rating >= 1 && meta.rating <= 5 {
            photo.rating = meta.rating
        }
        // Don't overwrite existing state with "unrated"
    }

    // MARK: - XMP Generation

    static func freshXMP(rating: Int) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
           xmp:Rating="\(rating)"
           xmp:CreatorTool="Cull">
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// Merge rating into an existing XMLDocument's rdf:Description
    private static func mergeInto(_ doc: XMLDocument, rating: Int) -> Bool {
        // Find rdf:Description element
        guard let descriptions = try? doc.nodes(forXPath: "//rdf:Description"),
              let desc = descriptions.first as? XMLElement else { return false }

        // Update or add xmp:Rating attribute
        let ns = "http://ns.adobe.com/xap/1.0/"
        if let existing = desc.attribute(forLocalName: "Rating", uri: ns) {
            existing.stringValue = "\(rating)"
        } else {
            let attr = XMLNode.attribute(
                withName: "xmp:Rating",
                uri: ns,
                stringValue: "\(rating)"
            ) as! XMLNode
            desc.addAttribute(attr)
        }

        // Ensure CreatorTool mentions Cull
        if desc.attribute(forLocalName: "CreatorTool", uri: ns) == nil {
            let attr = XMLNode.attribute(
                withName: "xmp:CreatorTool",
                uri: ns,
                stringValue: "Cull"
            ) as! XMLNode
            desc.addAttribute(attr)
        }

        return true
    }
}
