import FilletKernel
import Foundation

extension EvaluatedBody {
    /// The mesh to print or export: the shape tessellated finely, with its textures applied at
    /// full detail. Every 3MF/STL export goes through this.
    public func printMesh(quality: TextureQuality = .export) throws -> Mesh {
        let d = TextureEngine.exportDeflection
        let mesh = try shape.tessellate(linearDeflection: d.linear, angularDeflection: d.angular)
        guard !textures.isEmpty else { return mesh }
        return TextureEngine.apply(textures, to: mesh, of: shape, quality: quality)
    }
}

extension Array where Element == EvaluatedBody {
    /// ``EvaluatedBody/printMesh(quality:)`` of every body, made concurrently.
    public func printMeshes(quality: TextureQuality = .export) throws -> [Mesh] {
        var results = [Result<Mesh, Error>?](repeating: nil, count: count)
        results.withUnsafeMutableBufferPointer { buffer in
            let out = UnsafeMutableSendableBuffer(buffer)
            DispatchQueue.concurrentPerform(iterations: count) { i in
                out.buffer[i] = Result { try self[i].printMesh(quality: quality) }
            }
        }
        return try results.map { try $0!.get() }
    }
}

/// Lets `concurrentPerform` write distinct slots of one buffer.
private struct UnsafeMutableSendableBuffer<T>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<T>
    init(_ buffer: UnsafeMutableBufferPointer<T>) { self.buffer = buffer }
}
