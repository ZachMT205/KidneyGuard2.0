import SwiftUI
import UIKit
import AVFoundation
import Vision
import CoreImage
import Combine

// MARK: - ContentView: Shows the camera preview and takes measurements.
struct ContentView: UIViewControllerRepresentable {
    @Binding var pipetDiameter: String
    @Binding var density: String  // Liquid density (kg/m³)
    
    // MARK: Coordinator: Manages the camera session, photo capture, and analysis.
    class Coordinator: NSObject, AVCapturePhotoCaptureDelegate, ObservableObject {
        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        var parent: ContentView
        @Published var surfaceTension: String = "Tap to measure"
        var photoCompletion: ((UIImage) -> Void)?
        var cancellables = Set<AnyCancellable>()
        
        init(parent: ContentView) {
            self.parent = parent
            super.init()
            setupCamera()
            checkPermissions()
        }
        
        func setupCamera() {
            session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                         for: .video,
                                                         position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                print("Failed to get camera input")
                return
            }
            
            // Configure focus and exposure for close-up (droplet) capture.
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isLockingFocusWithCustomLensPositionSupported {
                    let desiredLensPosition: Float = 0.1  // Adjust for close-up focus.
                    device.setFocusModeLocked(lensPosition: desiredLensPosition, completionHandler: nil)
                }
                device.unlockForConfiguration()
            } catch {
                print("Error configuring device: \(error)")
            }
            
            if session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }
        
        func checkPermissions() {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                DispatchQueue.global(qos: .userInitiated).async {
                    self.session.startRunning()
                }
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.session.startRunning()
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.surfaceTension = "Camera access denied"
                        }
                    }
                }
            default:
                self.surfaceTension = "Camera access denied"
            }
        }
        
        @objc func capturePhoto() {
            print("capturePhoto triggered")
            let settings = AVCapturePhotoSettings()
            photoCompletion = { (image: UIImage) in
                DispatchQueue.main.async {
                    let result = self.calculateSurfaceTension(from: image,
                                                              pipetDiameter: self.parent.pipetDiameter,
                                                              density: self.parent.density)
                    print("Analysis result: \(String(describing: result))")
                    self.surfaceTension = result ?? "Measurement failed"
                }
            }
            output.capturePhoto(with: settings, delegate: self)
        }
        
        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishProcessingPhoto photo: AVCapturePhoto,
                         error: Error?) {
            if let error = error {
                print("Error capturing photo: \(error.localizedDescription)")
                return
            }
            guard let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                print("Failed to convert image data")
                return
            }
            photoCompletion?(image)
        }
        
        /// This function uses Vision to detect the droplet, computes a scale factor
        /// using the user-entered pipet diameter, and then calculates surface tension.
        func calculateSurfaceTension(from image: UIImage,
                                     pipetDiameter: String,
                                     density: String) -> String? {
            guard let cgImage = image.cgImage else {
                print("No CGImage found in image")
                return nil
            }
            
            let request = VNDetectContoursRequest()
            request.contrastAdjustment = 1.0
            request.detectDarkOnLight = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try handler.perform([request])
                guard let observation = request.results?.first as? VNContoursObservation else {
                    print("No contour observation found")
                    return nil
                }
                let contours = observation.topLevelContours
                guard let droplet = contours.max(by: { $0.pointCount < $1.pointCount }) else {
                    print("No droplet contour found")
                    return nil
                }
                let points = droplet.normalizedPoints
                // Convert normalized coordinate values to CGFloats.
                guard let minY = points.map({ CGFloat($0.y) }).min(),
                      let maxY = points.map({ CGFloat($0.y) }).max(),
                      let minX = points.map({ CGFloat($0.x) }).min(),
                      let maxX = points.map({ CGFloat($0.x) }).max() else {
                    print("Failed to determine bounding box")
                    return nil
                }
                
                let normalizedWidth: CGFloat = maxX - minX
                let normalizedHeight: CGFloat = maxY - minY
                
                // Compute a scale factor in mm/pixel.
                // Default: assume 0.01 mm/pixel if no valid pipet diameter is provided.
                var scaleFactor: CGFloat = CGFloat(0.01)
                if let d = Double(pipetDiameter), d > 0 {
                    let measuredWidthPixels = normalizedWidth * CGFloat(cgImage.width)
                    scaleFactor = CGFloat(d) / measuredWidthPixels
                }
                
                // Calculate droplet dimensions in mm.
                let dropletWidthMM: CGFloat = normalizedWidth * CGFloat(cgImage.width) * scaleFactor
                let dropletHeightMM: CGFloat = normalizedHeight * CGFloat(cgImage.height) * scaleFactor
                
                print("Measured droplet width: \(dropletWidthMM) mm, height: \(dropletHeightMM) mm")
                
                // Get density from user input or default to 1000 kg/m³.
                let rho: Double
                if let userDensity = Double(density), userDensity > 0 {
                    rho = userDensity
                } else {
                    rho = 1000.0
                }
                let g = 9.81  // Gravity in m/s²
                
                // Convert droplet dimensions from mm to m.
                let de = Double(dropletWidthMM) / 1000.0
                let h = Double(dropletHeightMM) / 1000.0
                
                // Calculate surface tension (N/m) with density in the formula.
                let tension = rho * g * de * h
                
                // Convert tension to mN/m.
                return String(format: "Surface Tension: %.1f mN/m", tension * 1000)
            } catch {
                print("Error performing contour request: \(error.localizedDescription)")
                return nil
            }
        }
    } // End of Coordinator
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(parent: self)
    }
    
    func makeUIViewController(context: UIViewControllerRepresentableContext<ContentView>) -> UIViewController {
        let vc = UIViewController()
        
        // Set up the camera preview layer.
        let previewLayer = AVCaptureVideoPreviewLayer(session: context.coordinator.session)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        previewLayer.frame = vc.view.bounds
        vc.view.layer.addSublayer(previewLayer)
        
        // Create a button for capturing a photo.
        let button = UIButton(type: .system)
        button.setTitle("Start Analysis", for: .normal)
        button.backgroundColor = UIColor.systemBlue
        button.setTitleColor(UIColor.white, for: .normal)
        button.layer.cornerRadius = 8
        button.clipsToBounds = true
        button.addTarget(context.coordinator,
                         action: #selector(context.coordinator.capturePhoto),
                         for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(button)
        
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 20),
            button.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -120),
            button.heightAnchor.constraint(equalToConstant: 40)
        ])
        
        // Create a label to display the measurement result.
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = UIColor.white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -60),
            label.heightAnchor.constraint(equalToConstant: 40)
        ])
        
        context.coordinator.$surfaceTension
            .receive(on: DispatchQueue.main)
            .sink { text in
                label.text = text
            }
            .store(in: &context.coordinator.cancellables)
        
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<ContentView>) {
        // No dynamic updates needed.
    }
}

// MARK: - MainView: Root SwiftUI view with inputs for pipet diameter and density.
struct MainView: View {
    @State private var pipetDiameter: String = ""
    @State private var density: String = ""
    
    var body: some View {
        VStack {
            TextField("Enter pipet diameter (mm)", text: $pipetDiameter)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
                .keyboardType(.decimalPad)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                            to: nil, from: nil, for: nil)
                        }
                    }
                }
            TextField("Enter density (kg/m³)", text: $density)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding([.horizontal, .bottom])
                .keyboardType(.decimalPad)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                            to: nil, from: nil, for: nil)
                        }
                    }
                }
            ContentView(pipetDiameter: $pipetDiameter, density: $density)
                .edgesIgnoringSafeArea(.all)
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
