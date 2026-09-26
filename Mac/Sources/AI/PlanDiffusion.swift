import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// Stable Diffusion 1.5 guided by ControlNets, running on Core ML: turns the depth and
/// segmentation renders of a floor plan into a photograph of the same space.
///
/// Built from the vendored Apple pipeline pieces in `Diffusion/`; unlike Apple's pipeline it gives
/// each ControlNet its own strength and lets it stop early, which keeps the geometry exact while
/// leaving the last steps free to add realistic detail.
final class PlanDiffusion {
    struct Control {
        /// ControlNet model name (file name in `controlnet/` without `.mlmodelc`).
        var model: String
        var image: CGImage
        var weight: Float
        /// Fraction of the steps (from the start) during which the ControlNet is applied.
        var end: Float = 1
    }

    struct Request {
        var prompt: String
        var negativePrompt: String
        var controls: [Control]
        var seed: UInt32
        var steps = 25
        var guidance: Float = 7
        /// Optional image to start from (image-to-image), with how much of it to repaint (0...1).
        var startingImage: CGImage?
        var strength: Float = 1
    }

    enum PipelineError: LocalizedError {
        case missingModel(String)
        case wrongImageSize(Int, Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .missingModel(let name): "The AI model file “\(name)” is missing. Download the model again."
            case .wrongImageSize(let w, let h): "Control images must be \(w) × \(h) pixels."
            case .cancelled: "Rendering was cancelled."
            }
        }
    }

    let directory: URL
    private let configuration: MLModelConfiguration
    private let textEncoder: TextEncoder
    private let unet: Unet
    private let decoder: VAEDecoder
    private let encoder: VAEEncoder?
    private var controlNets: [String: ManagedMLModel] = [:]
    private var zeroResiduals: [String: MLShapedArray<Float32>]?

    /// Loads (lazily) the models in `directory`: ControlledUnet, TextEncoder, VAEDecoder, optional
    /// VAEEncoder, vocab.json, merges.txt and `controlnet/*.mlmodelc`.
    init(directory: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        self.directory = directory
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.configuration = configuration
        func url(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw PipelineError.missingModel(name) }
            return url
        }
        let tokenizer = try BPETokenizer(mergesAt: url("merges.txt"), vocabularyAt: url("vocab.json"))
        textEncoder = TextEncoder(tokenizer: tokenizer, modelAt: try url("TextEncoder.mlmodelc"), configuration: configuration)
        unet = Unet(modelAt: try url("ControlledUnet.mlmodelc"), configuration: configuration)
        decoder = VAEDecoder(modelAt: try url("VAEDecoder.mlmodelc"), configuration: configuration)
        encoder = (try? url("VAEEncoder.mlmodelc")).map { VAEEncoder(modelAt: $0, configuration: configuration) }
    }

    /// Output size in pixels (the latent size × 8).
    var imageSize: (width: Int, height: Int) {
        let shape = unet.latentSampleShape
        return (shape[3] * 8, shape[2] * 8)
    }

    func loadResources(controls: [String]) throws {
        try textEncoder.loadResources()
        try unet.loadResources()
        try decoder.loadResources()
        for name in controls { try controlNet(name).loadResources() }
    }

    func unloadResources() {
        textEncoder.unloadResources()
        unet.unloadResources()
        decoder.unloadResources()
        encoder?.unloadResources()
        controlNets.values.forEach { $0.unloadResources() }
    }

    private func controlNet(_ name: String) throws -> ManagedMLModel {
        if let model = controlNets[name] { return model }
        let url = directory.appendingPathComponent("controlnet/\(name).mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { throw PipelineError.missingModel("controlnet/\(name).mlmodelc") }
        let model = ManagedMLModel(modelAt: url, configuration: configuration)
        controlNets[name] = model
        return model
    }

    /// Generates one image. `progress` gets (step, stepCount) and returns false to cancel.
    func generate(_ request: Request, progress: (Int, Int) -> Bool = { _, _ in true }) throws -> CGImage {
        let (width, height) = imageSize

        // Text conditioning: [negative, positive] → [2, 768, 1, 77].
        let positive = try textEncoder.encode(request.prompt)
        let negative = try textEncoder.encode(request.negativePrompt)
        let hiddenStates = Self.hiddenStates(MLShapedArray(concatenating: [negative, positive], alongAxis: 0))

        // Control images, duplicated for the two guidance branches.
        let conditions = try request.controls.map { control -> MLShapedArray<Float32> in
            guard control.image.width == width, control.image.height == height else { throw PipelineError.wrongImageSize(width, height) }
            let array = try control.image.planarRGBShapedArray(minValue: 0, maxValue: 1)
            return MLShapedArray(concatenating: [array, array], alongAxis: 0)
        }
        let nets = try request.controls.map { try controlNet($0.model) }

        let scheduler = DPMSolverMultistepScheduler(stepCount: request.steps, timeStepSpacing: .karras)
        var random: RandomSource = TorchRandomSource(seed: request.seed)
        var shape = unet.latentSampleShape
        shape[0] = 1
        let noise = MLShapedArray<Float32>(converting: random.normalShapedArray(shape, mean: 0, stdev: Double(scheduler.initNoiseSigma)))
        var latents = noise
        var strength: Float?
        if let image = request.startingImage, request.strength < 1, let encoder {
            let encoded = try encoder.encode(image, scaleFactor: 0.18215, random: &random)
            latents = scheduler.addNoise(originalSample: encoded, noise: [noise], strength: request.strength)[0]
            strength = request.strength
        }

        let timeSteps = scheduler.calculateTimesteps(strength: strength)
        let trace = ProcessInfo.processInfo.environment["SCANSPACE_AI_TRACE"] != nil
        var controlTime = 0.0, unetTime = 0.0, schedulerTime = 0.0
        for (step, t) in timeSteps.enumerated() {
            var mark = Date()
            let input = MLShapedArray<Float32>(concatenating: [latents, latents], alongAxis: 0)
            let fraction = Float(step) / Float(max(1, timeSteps.count))
            var residuals: [String: MLShapedArray<Float32>]?
            for (index, control) in request.controls.enumerated() where fraction < control.end && control.weight > 0 {
                let output = try Self.runControlNet(nets[index], latents: input, timeStep: t, hiddenStates: hiddenStates, condition: conditions[index])
                residuals = Self.accumulate(output, weight: control.weight, into: residuals)
            }
            // The controlled UNet always expects the residual inputs.
            if residuals == nil { residuals = try zeros() }
            controlTime += Date().timeIntervalSince(mark); mark = Date()
            let prediction = try unet.predictNoise(latents: [input], timeStep: t, hiddenStates: hiddenStates, additionalResiduals: [residuals!])[0]
            unetTime += Date().timeIntervalSince(mark); mark = Date()
            let guided = Self.guidance(prediction, scale: request.guidance)
            latents = scheduler.step(output: guided, timeStep: t, sample: latents)
            schedulerTime += Date().timeIntervalSince(mark)
            if !progress(step + 1, timeSteps.count) { throw PipelineError.cancelled }
        }
        let decodeStart = Date()
        guard let image = try decoder.decode([latents], scaleFactor: 0.18215).first else { throw PipelineError.missingModel("VAEDecoder") }
        if trace {
            FileHandle.standardError.write(String(format: "trace: controlnets %.2fs, unet %.2fs, scheduler %.2fs, decode %.2fs (%d steps)\n",
                                                  controlTime, unetTime, schedulerTime, Date().timeIntervalSince(decodeStart), timeSteps.count).data(using: .utf8)!)
        }
        return image
    }

    // MARK: - Helpers

    private static func runControlNet(_ model: ManagedMLModel, latents: MLShapedArray<Float32>, timeStep: Int,
                                      hiddenStates: MLShapedArray<Float32>, condition: MLShapedArray<Float32>) throws -> [String: MLShapedArray<Float32>] {
        let t = MLShapedArray<Float32>(scalars: [Float(timeStep), Float(timeStep)], shape: [2])
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "sample": MLMultiArray(latents),
            "timestep": MLMultiArray(t),
            "encoder_hidden_states": MLMultiArray(hiddenStates),
            "controlnet_cond": MLMultiArray(condition),
        ])
        let result = try model.perform { try $0.prediction(from: input) }
        var outputs: [String: MLShapedArray<Float32>] = [:]
        for name in result.featureNames {
            if let array = result.featureValue(for: name)?.multiArrayValue {
                outputs[name] = MLShapedArray<Float32>(converting: array)
            }
        }
        return outputs
    }

    /// `into + weight × output`, element-wise per residual.
    private static func accumulate(_ output: [String: MLShapedArray<Float32>], weight: Float,
                                   into existing: [String: MLShapedArray<Float32>]?) -> [String: MLShapedArray<Float32>] {
        var result = existing ?? [:]
        for (name, value) in output {
            var target = result[name] ?? MLShapedArray<Float32>(repeating: 0, shape: value.shape)
            var w = weight
            value.withUnsafeShapedBufferPointer { source, _, _ in
                target.withUnsafeMutableShapedBufferPointer { destination, _, _ in
                    vDSP_vsma(source.baseAddress!, 1, &w, destination.baseAddress!, 1, destination.baseAddress!, 1, vDSP_Length(source.count))
                }
            }
            result[name] = target
        }
        return result
    }

    private func zeros() throws -> [String: MLShapedArray<Float32>] {
        if let zeroResiduals { return zeroResiduals }
        let inputs = try unet.models[0].perform { $0.modelDescription.inputDescriptionsByName }
        var zeros: [String: MLShapedArray<Float32>] = [:]
        for (name, description) in inputs where name.hasPrefix("additional_residual") {
            let shape = description.multiArrayConstraint?.shape.map(\.intValue) ?? []
            zeros[name] = MLShapedArray<Float32>(repeating: 0, shape: shape)
        }
        zeroResiduals = zeros
        return zeros
    }

    /// [2, 77, 768] → [2, 768, 1, 77], the layout the Core ML UNet takes.
    private static func hiddenStates(_ embedding: MLShapedArray<Float32>) -> MLShapedArray<Float32> {
        let s = embedding.shape
        return MLShapedArray<Float32>(unsafeUninitializedShape: [s[0], s[2], 1, s[1]]) { result, _ in
            embedding.withUnsafeShapedBufferPointer { source, _, _ in
                for b in 0..<s[0] {
                    for token in 0..<s[1] {
                        for channel in 0..<s[2] {
                            result.initializeElement(at: (b * s[2] + channel) * s[1] + token, to: source[(b * s[1] + token) * s[2] + channel])
                        }
                    }
                }
            }
        }
    }

    /// Classifier-free guidance: uncond + scale × (text − uncond), from a [2, …] prediction.
    private static func guidance(_ noise: MLShapedArray<Float32>, scale: Float) -> MLShapedArray<Float32> {
        var shape = noise.shape
        shape[0] = 1
        let half = noise.scalarCount / 2
        return MLShapedArray<Float32>(unsafeUninitializedShape: shape) { result, _ in
            noise.withUnsafeShapedBufferPointer { scalars, _, _ in
                for i in 0..<half {
                    result.initializeElement(at: i, to: scalars[i] + scale * (scalars[half + i] - scalars[i]))
                }
            }
        }
    }
}
