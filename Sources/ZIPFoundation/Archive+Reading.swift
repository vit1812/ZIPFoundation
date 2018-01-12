//
//  Archive+Reading.swift
//  ZIPFoundation
//
//  Copyright © 2017 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/LICENSE for license information.
//

import Foundation

extension Archive {
    /// Read a ZIP `Entry` from the receiver and write it to `url`.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - url: The destination file URL.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    /// - Returns: The checksum of the processed content.
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
    public func extract(_ entry: Entry, to url: URL, bufferSize: UInt32 = defaultReadChunkSize,
                        progress: Progress? = nil) throws -> CRC32 {
        let fileManager = FileManager()
        var checksum = CRC32(0)
        switch entry.type {
        case .file:
            guard !fileManager.fileExists(atPath: url.path) else {
                throw CocoaError.error(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path], url: nil)
            }
            try fileManager.createParentDirectoryStructure(for: url)
            let destinationFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: url.path)
            let destinationFile: UnsafeMutablePointer<FILE> = fopen(destinationFileSystemRepresentation, "wb+")
            defer { fclose(destinationFile) }
            let consumer = { _ = try Data.write(chunk: $0, to: destinationFile) }
            checksum = try self.extract(entry, bufferSize: bufferSize, progress: progress, consumer: consumer)
        case .directory:
            let consumer = { (_: Data) in
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            }
            checksum = try self.extract(entry, bufferSize: bufferSize, progress: progress, consumer: consumer)
        case .symlink:
            guard !fileManager.fileExists(atPath: url.path) else {
                throw CocoaError.error(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path], url: nil)
            }
            let consumer = { (data: Data) in
                guard let linkPath = String(data: data, encoding: .utf8) else { throw ArchiveError.invalidEntryPath }
                try fileManager.createParentDirectoryStructure(for: url)
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: linkPath)
            }
            checksum = try self.extract(entry, bufferSize: bufferSize, progress: progress, consumer: consumer)
        }
        let attributes = FileManager.attributes(from: entry.centralDirectoryStructure)
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        return checksum
    }

    /// Read a ZIP `Entry` from the receiver and forward its contents to a `Consumer` closure.
    ///
    /// - Parameters:
    ///   - entry: The ZIP `Entry` to read.
    ///   - bufferSize: The maximum size of the read buffer and the decompression buffer (if needed).
    ///   - consumer: A closure that consumes contents of `Entry` as `Data` chunks.
    /// - Returns: The checksum of the processed content.
    /// - Throws: An error if the destination file cannot be written or the entry contains malformed content.
    public func extract(_ entry: Entry, bufferSize: UInt32 = defaultReadChunkSize,
                        progress: Progress? = nil, consumer: Consumer) throws -> CRC32 {
        var checksum = CRC32(0)
        let localFileHeader = entry.localFileHeader
        fseek(self.archiveFile, entry.dataOffset, SEEK_SET)
        switch entry.type {
        case .file:
            guard let compressionMethod = CompressionMethod(rawValue: localFileHeader.compressionMethod) else {
                throw ArchiveError.invalidCompressionMethod
            }
            switch compressionMethod {
            case .none: checksum = try self.readUncompressed(entry: entry, bufferSize: bufferSize,
                                                             progress: progress, with: consumer)
            case .deflate: checksum = try self.readCompressed(entry: entry, bufferSize: bufferSize,
                                                              progress: progress, with: consumer)
            }
        case .directory:
            progress?.totalUnitCount = 1
            defer { progress?.completedUnitCount = 1 }
            try consumer(Data())
        case .symlink:
            progress?.totalUnitCount = 1
            defer { progress?.completedUnitCount = 1 }
            let localFileHeader = entry.localFileHeader
            let size = Int(localFileHeader.compressedSize)
            let data = try Data.readChunk(of: size, from: self.archiveFile)
            checksum = data.crc32(checksum: 0)
            try consumer(data)
        }
        return checksum
    }

    // MARK: - Helpers

    private func readUncompressed(entry: Entry, bufferSize: UInt32,
                                  progress: Progress? = nil, with consumer: Consumer) throws -> CRC32 {
        let size = Int(entry.centralDirectoryStructure.uncompressedSize)
        progress?.totalUnitCount = Int64(size)
        defer { progress?.completedUnitCount = Int64(size) }
        return try Data.consumePart(of: self.archiveFile, size: size, chunkSize: Int(bufferSize), consumer: { (data) in
            progress?.completedUnitCount += Int64(data.count)
            try consumer(data)
        })
    }

    private func readCompressed(entry: Entry, bufferSize: UInt32,
                                progress: Progress? = nil, with consumer: Consumer) throws -> CRC32 {
        let size = entry.centralDirectoryStructure.compressedSize
        progress?.totalUnitCount = Int64(entry.centralDirectoryStructure.uncompressedSize)
        defer { progress?.completedUnitCount = Int64(entry.centralDirectoryStructure.uncompressedSize) }
        return try Data.decompress(size: Int(size), bufferSize: Int(bufferSize), provider: { (_, chunkSize) -> Data in
            return try Data.readChunk(of: chunkSize, from: self.archiveFile)
        }, consumer: { (data) in
            progress?.completedUnitCount += Int64(data.count)
            try consumer(data)
        })
    }
}
