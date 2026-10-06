import SwiftUI
import PhotosUI
import CoreTransferable
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import UIKit

@main struct VideoLabApp: App { var body: some Scene { WindowGroup { ContentView() } } }

struct Movie: Transferable {
 let url: URL
 static var transferRepresentation: some TransferRepresentation {
  FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { r in
   let ext=r.file.pathExtension.isEmpty ? "mov":r.file.pathExtension
   let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
   try? FileManager.default.removeItem(at:d); try FileManager.default.copyItem(at:r.file,to:d); return Movie(url:d)
  }
 }
}

enum Engine:String,CaseIterable,Identifiable {
 case native="Fast Native", detail="AI Detail", temporal="Temporal Pro", anime="Anime / CG"
 var id:String{rawValue}
 var note:String { switch self {
  case .native:return "VideoToolbox + Core Image — الأسرع والأقل استهلاكًا"
  case .detail:return "Real-ESRGAN x2plus/x4plus — تحسين AI فعلي لكل فريم"
  case .temporal:return "Real-ESRGAN General — سريع ومتوازن للفيديو"
  case .anime:return "Real-ESRGAN AnimeVideo — مخصص للأنمي والرسوم"
 }}
}
enum Scale:String,CaseIterable,Identifiable { case x1="Original",x2="2×",x4="4×";var id:String{rawValue};var value:CGFloat{self == .x4 ? 4:self == .x2 ? 2:1} }
enum Codec:String,CaseIterable,Identifiable { case hevc="HEVC",h264="H.264";var id:String{rawValue} }

@MainActor final class Processor:ObservableObject {
 @Published var progress = 0.0
 @Published var message = "جاهز"
 @Published var output: URL?
 @Published var working = false
 func process(_ input:URL,engine:Engine,scale:Scale,codec:Codec,denoise:Double,sharp:Double) async {
  working=true;progress=0;output=nil;message="تحليل الفيديو…"
  do {
   let asset=AVURLAsset(url:input); guard let track=try await asset.loadTracks(withMediaType:.video).first else{throw NSError(domain:"VideoLab",code:1,userInfo:[NSLocalizedDescriptionKey:"لا يوجد مسار فيديو"])}
   let size=try await track.load(.naturalSize); let transform=try await track.load(.preferredTransform)
   let transformed=size.applying(transform); let base=CGSize(width:abs(transformed.width),height:abs(transformed.height))
   var factor=scale.value
   let maxSide=max(base.width,base.height)
   if maxSide*factor>3840 { factor=3840/maxSide }
   let outSize=CGSize(width:max(2,(base.width*factor).rounded(.down)),height:max(2,(base.height*factor).rounded(.down)))
   let ai: RealESRGANEngine? = {
    do {
     switch engine {
     case .detail: return try RealESRGANEngine(kind: scale == .x2 ? .x2plus : .x4plus)
     case .temporal: return try RealESRGANEngine(kind: .general)
     case .anime: return try RealESRGANEngine(kind: .animevideo)
     case .native: return nil
     }
    } catch { return nil }
   }()
   if engine != .native && ai == nil {
    throw NSError(domain:"VideoLabAI",code:20,userInfo:[NSLocalizedDescriptionKey:"تعذر تحميل نموذج Real-ESRGAN المضمّن"])
   }
   let composition = AVMutableVideoComposition(asset: asset) { request in
    var image = request.sourceImage
    if denoise > 0 {
     let n = CIFilter.noiseReduction(); n.inputImage = image; n.noiseLevel = Float(min(0.1, denoise * 0.1)); n.sharpness = 0.4; image = n.outputImage ?? image
    }
    if sharp > 0 {
     let s = CIFilter.sharpenLuminance(); s.inputImage = image; s.sharpness = Float(sharp * 1.2); image = s.outputImage ?? image
    }
    if let ai {
     do { image = try ai.upscale(image, target: outSize) }
     catch { request.finish(with: error); return }
    } else {
     let e = image.extent
     image = image.transformed(by: CGAffineTransform(scaleX: outSize.width / e.width, y: outSize.height / e.height))
    }
    request.finish(with: image.cropped(to: CGRect(origin: .zero, size: outSize)), context: nil)
   }
   composition.renderSize=outSize
   let fps=try await track.load(.nominalFrameRate); composition.frameDuration=CMTime(value:1,timescale:CMTimeScale(max(24,min(60,Int32(fps.rounded())))))
   let out=FileManager.default.temporaryDirectory.appendingPathComponent("VideoLab-"+UUID().uuidString).appendingPathExtension("mov")
   guard let export=AVAssetExportSession(asset:asset,presetName: codec == .hevc ? AVAssetExportPresetHEVCHighestQuality:AVAssetExportPresetHighestQuality) else{throw NSError(domain:"VideoLab",code:2,userInfo:[NSLocalizedDescriptionKey:"تعذر إنشاء جلسة التصدير"])}
   export.videoComposition = composition; export.outputURL = out; export.outputFileType = .mov; export.shouldOptimizeForNetworkUse = false
   message = engine == .native ? "معالجة Native…" : "معالجة \(engine.rawValue)…"
   let watcher = Task { while !Task.isCancelled { self.progress = Double(export.progress); try? await Task.sleep(for: .milliseconds(150)) } }
   await export.export(); watcher.cancel()
   guard export.status == .completed else{throw export.error ?? NSError(domain:"VideoLab",code:3,userInfo:[NSLocalizedDescriptionKey:"فشل التصدير"])}
   output = out; progress = 1; message = "تم — جاهز للحفظ أو الإرسال إلى TikTok"
  } catch { message=error.localizedDescription }
  working = false
 }
}

struct ShareSheet:UIViewControllerRepresentable {
 let url:URL
 func makeUIViewController(context:Context)->UIActivityViewController{UIActivityViewController(activityItems:[url],applicationActivities:nil)}
 func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){}
}

struct ContentView: View {
 @StateObject private var p = Processor()
 @State private var item: PhotosPickerItem?
 @State private var movie: Movie?
 @State private var engine: Engine = .native
 @State private var scale: Scale = .x2
 @State private var codec: Codec = .hevc
 @State private var denoise = 0.25
 @State private var sharp = 0.35
 @State private var share = false

 var body: some View {
  NavigationStack {
   ZStack {
    LinearGradient(colors: [.black, Color(red: 0.025, green: 0.055, blue: 0.08)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    ScrollView {
     VStack(spacing: 18) {
      header
      pickerCard
      engineCard
      outputCard
      actionCard
      Text("النماذج AI مضمّنة وتعمل محليًا على الجهاز. لا يوجد TikTok API أو Token. TikTok قد يعيد معالجة الملف بعد استلامه.")
       .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
     }.padding(18)
    }
   }.preferredColorScheme(.dark)
  }
  .onChange(of: item) { _, value in
   guard let value else { return }
   Task { movie = try? await value.loadTransferable(type: Movie.self); p.output = nil; p.message = "جاهز" }
  }
  .sheet(isPresented: $share) { if let url = p.output { ShareSheet(url: url) } }
 }

 private var header: some View {
  VStack(spacing: 5) {
   Image(systemName: "sparkles.tv.fill").font(.system(size: 55)).foregroundStyle(.cyan)
   Text("VideoLab").font(.system(size: 34, weight: .bold, design: .rounded))
   Text("Upscale • Restore • TikTok").foregroundStyle(.secondary)
  }
 }

 private var pickerCard: some View {
  card {
   PhotosPicker(selection: $item, matching: .videos) {
    HStack {
     Image(systemName: "film.stack")
     Text(movie == nil ? "اختر الفيديو الأصلي" : "تم اختيار الفيديو")
     Spacer(); Image(systemName: "chevron.right")
    }.padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
   }
  }
 }

 private var engineCard: some View {
  card {
   Text("المحرك").font(.headline)
   ForEach(Engine.allCases) { e in
    Button { engine = e } label: {
     HStack(alignment: .top) {
      Image(systemName: engine == e ? "checkmark.circle.fill" : "circle").foregroundStyle(engine == e ? .cyan : .secondary)
      VStack(alignment: .leading) { Text(e.rawValue).foregroundStyle(.primary); Text(e.note).font(.caption).foregroundStyle(.secondary) }
      Spacer()
     }.padding(.vertical, 5)
    }
   }
  }
 }

 private var outputCard: some View {
  card {
   Text("الإخراج").font(.headline)
   Picker("Scale", selection: $scale) { ForEach(Scale.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
   Picker("Codec", selection: $codec) { ForEach(Codec.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
   HStack { Text("Denoise"); Slider(value: $denoise); Text("\(Int(denoise * 100))").monospacedDigit().frame(width: 30) }
   HStack { Text("Sharpen"); Slider(value: $sharp); Text("\(Int(sharp * 100))").monospacedDigit().frame(width: 30) }
  }
 }

 private var actionCard: some View {
  card {
   Text(p.message).font(.footnote)
   if p.working { ProgressView(value: p.progress); Text("\(Int(p.progress * 100))%").font(.caption).monospacedDigit() }
   Button {
    guard let movie else { return }
    Task { await p.process(movie.url, engine: engine, scale: scale, codec: codec, denoise: denoise, sharp: sharp) }
   } label: { Label("ابدأ التحسين", systemImage: "wand.and.stars").frame(maxWidth: .infinity).padding(8) }
   .buttonStyle(.borderedProminent).tint(.cyan).disabled(movie == nil || p.working)
   if p.output != nil {
    Button { share = true } label: { Label("إرسال الملف الناتج إلى TikTok / مشاركة", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.bordered)
   }
  }
 }

 private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
  VStack(alignment: .leading, spacing: 12) { content() }.padding(17)
   .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23))
   .overlay(RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.08)))
 }
}
