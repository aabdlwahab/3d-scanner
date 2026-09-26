import AppKit
import CoreGraphics
import SceneKit
import simd

/// AI retexturing of a LiDAR scan: render the textured scan from the capture's own camera
/// positions, let the diffusion model clean each render (guided by the scan's depth), and bake the
/// cleaned images back onto the mesh with the regular texturing pipeline.
enum ScanRetexture {
    /// A capture camera cropped to the diffusion model's 3:2 frame (principal point centred).
    struct View {
        var record: KeyframeRecord
        var camera: PinholeCamera
    }

    /// `count` keyframes spread evenly through the capture, cropped and scaled to `width` × `height`.
    static func views(_ index: KeyframeIndex, count: Int, width: Int, height: Int) -> [View] {
        let frames = index.frames.filter { $0.intrinsics.count == 4 && $0.transform.count == 16 }
        guard !frames.isEmpty else { return [] }
        let step = max(1, frames.count / max(1, count))
        return stride(from: step / 2, to: frames.count, by: step).prefix(count).map { i in
            let record = frames[i]
            // Keep the full width; crop the height to 3:2 around the centre.
            let scale = Float(width) / Float(record.imageWidth)
            let f = record.intrinsics[1] * scale
            let camera = PinholeCamera(cameraToWorld: simd_float4x4(columnMajor: record.transform), fx: record.intrinsics[0] * scale, fy: f,
                                       cx: Float(width) / 2, cy: Float(height) / 2, width: width, height: height)
            return View(record: record, camera: camera)
        }
    }

    static func cameraNode(_ camera: PinholeCamera) -> SCNNode {
        let node = SCNNode()
        node.camera = SCNCamera()
        node.camera?.projectionDirection = .vertical
        node.camera?.fieldOfView = CGFloat(2 * atan(Float(camera.height) / 2 / camera.fy) * 180 / .pi)
        node.camera?.zNear = 0.05
        node.camera?.zFar = 100
        node.camera?.wantsHDR = false
        node.simdTransform = camera.cameraToWorld
        return node
    }

    /// Color and inverse-depth renders of `scan` from `camera`.
    static func render(_ scan: SCNNode, camera: PinholeCamera) throws -> (color: CGImage, depth: CGImage) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PlanRenderer.RenderError.noMetal }
        let size = CGSize(width: camera.width, height: camera.height)
        func snapshot(_ node: SCNNode) throws -> [UInt8] {
            let scene = SCNScene()
            scene.background.contents = NSColor.black
            scene.rootNode.addChildNode(node)
            let cam = cameraNode(camera)
            scene.rootNode.addChildNode(cam)
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = cam
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            guard let pixels = RGBAPixels(image: image, width: camera.width, height: camera.height) else { throw PlanRenderer.RenderError.renderFailed }
            return pixels.bytes
        }
        let color = try snapshot(scan.clone())

        // Depth: same geometry with a shader writing normalised inverse depth.
        let depthNode = scan.clone()
        let modifier = """
        #pragma body
        float z = max(-_surface.position.z, 0.05);
        float v = clamp((1.0 / z - 1.0 / 12.0) / (1.0 / 0.3 - 1.0 / 12.0), 0.0, 1.0);
        float l = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
        _output.color = float4(l, l, l, 1.0);
        """
        depthNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry?.copy() as? SCNGeometry else { return }
            geometry.materials = geometry.materials.map { _ in
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.isDoubleSided = true
                material.shaderModifiers = [.fragment: modifier]
                return material
            }
            node.geometry = geometry
        }
        let depth = try snapshot(depthNode)
        let n = camera.width * camera.height
        var rgb = [UInt8](repeating: 0, count: n * 3), gray = [UInt8](repeating: 0, count: n * 3)
        for i in 0..<n {
            rgb[3 * i] = color[4 * i]; rgb[3 * i + 1] = color[4 * i + 1]; rgb[3 * i + 2] = color[4 * i + 2]
            gray[3 * i] = depth[4 * i]; gray[3 * i + 1] = depth[4 * i]; gray[3 * i + 2] = depth[4 * i]
        }
        guard let colorImage = RGBAPixels.image(rgb: rgb, width: camera.width, height: camera.height),
              let depthImage = RGBAPixels.image(rgb: gray, width: camera.width, height: camera.height)
        else { throw PlanRenderer.RenderError.renderFailed }
        return (colorImage, depthImage)
    }

    /// The original photo of a keyframe, centre-cropped and scaled like the view.
    static func photo(_ view: View, files: ScanFiles) -> CGImage? {
        guard let image = ImageFiles.loadImage(files.frameFile(view.record.image), maxPixelSize: view.record.imageWidth) else { return nil }
        let w = view.camera.width, h = view.camera.height
        let cropH = min(image.height, image.width * h / w)
        let rect = CGRect(x: 0, y: (image.height - cropH) / 2, width: image.width, height: cropH)
        guard let cropped = image.cropping(to: rect),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
