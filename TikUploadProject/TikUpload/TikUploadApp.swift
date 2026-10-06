import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

@main struct TikUploadApp: App { var body: some Scene { WindowGroup { ContentView() } } }

struct Movie: Transferable {
 let url: URL
 static var transferRepresentation: some TransferRepresentation {
  FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { r in
   let ext=r.file.pathExtension.isEmpty ? "mp4":r.file.pathExtension
   let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
   try? FileManager.default.removeItem(at:d); try FileManager.default.copyItem(at:r.file,to:d); return Movie(url:d)
  }
 }
}
enum UploadState { case idle, preparing, uploading(Double), sent, failed(String) }
struct InitResponse: Decodable {
 struct Payload:Decodable { let publish_id:String?; let upload_url:String? }
 struct APIError:Decodable { let code:String; let message:String? }
 let data:Payload?; let error:APIError?
}
@MainActor final class Uploader:ObservableObject {
 @Published var state:UploadState = .idle
 func upload(_ file:URL,token:String) async {
  do {
   state = .preparing
   let size=Int64(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
   guard size>0 else { throw NSError(domain:"TikUpload",code:1,userInfo:[NSLocalizedDescriptionKey:"تعذر قراءة الفيديو"]) }
   let five:Int64=5_000_000, ten:Int64=10_000_000, chunk=size<five ? size:min(ten,size)
   let count=max(1,Int(size/chunk))
   var q=URLRequest(url:URL(string:"https://open.tiktokapis.com/v2/post/publish/inbox/video/init/")!)
   q.httpMethod="POST"; q.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization"); q.setValue("application/json; charset=UTF-8",forHTTPHeaderField:"Content-Type")
   q.httpBody=try JSONSerialization.data(withJSONObject:["source_info":["source":"FILE_UPLOAD","video_size":size,"chunk_size":chunk,"total_chunk_count":count]])
   let (d,r)=try await URLSession.shared.data(for:q)
   guard let h=r as? HTTPURLResponse,(200...299).contains(h.statusCode) else { throw apiError(d,r) }
   let x=try JSONDecoder().decode(InitResponse.self,from:d)
   guard x.error?.code=="ok",let s=x.data?.upload_url,let u=URL(string:s) else { throw NSError(domain:"TikTok",code:2,userInfo:[NSLocalizedDescriptionKey:x.error?.message ?? x.error?.code ?? "TikTok API error"]) }
   try await send(file,to:u,size:size,chunk:chunk); state = .sent
  } catch { state = .failed(error.localizedDescription) }
 }
 private func send(_ file:URL,to url:URL,size:Int64,chunk:Int64) async throws {
  let f=try FileHandle(forReadingFrom:file); defer{try? f.close()}; var offset:Int64=0
  while offset<size {
   let remaining=size-offset; var length=min(chunk,remaining)
   if remaining>chunk && remaining-chunk<5_000_000 { length=remaining }
   try f.seek(toOffset:UInt64(offset))
   guard let data=try f.read(upToCount:Int(length)),!data.isEmpty else { throw NSError(domain:"TikUpload",code:3,userInfo:[NSLocalizedDescriptionKey:"تعذر قراءة جزء من الفيديو"]) }
   let end=offset+Int64(data.count)-1; var q=URLRequest(url:url); q.httpMethod="PUT"
   let ext=file.pathExtension.lowercased(); q.setValue(ext=="mov" ? "video/quicktime":(ext=="webm" ? "video/webm":"video/mp4"),forHTTPHeaderField:"Content-Type")
   q.setValue(String(data.count),forHTTPHeaderField:"Content-Length"); q.setValue("bytes \(offset)-\(end)/\(size)",forHTTPHeaderField:"Content-Range")
   let (reply,response)=try await URLSession.shared.upload(for:q,from:data)
   guard let h=response as? HTTPURLResponse,[200,201,206].contains(h.statusCode) else { throw apiError(reply,response) }
   offset=end+1; state = .uploading(Double(offset)/Double(size))
  }
 }
 private func apiError(_ d:Data,_ r:URLResponse)->Error { let c=(r as? HTTPURLResponse)?.statusCode ?? -1; return NSError(domain:"TikTok",code:c,userInfo:[NSLocalizedDescriptionKey:"TikTok HTTP \(c): "+(String(data:d,encoding:.utf8) ?? "")]) }
}
struct ContentView:View {
 @StateObject var up=Uploader(); @AppStorage("tt_token") var token=""; @State var pick:PhotosPickerItem?; @State var movie:Movie?; @State var loading=false; @State var show=false
 var busy:Bool { if case .preparing=up.state{return true}; if case .uploading=up.state{return true}; return false }
 var body:some View {
  NavigationStack { ZStack {
   LinearGradient(colors:[.black,Color(red:0.03,green:0.07,blue:0.09)],startPoint:.top,endPoint:.bottom).ignoresSafeArea()
   ScrollView { VStack(spacing:20) {
    Image(systemName:"arrow.up.circle.fill").font(.system(size:64)).foregroundStyle(.cyan)
    Text("TikUpload").font(.system(size:34,weight:.bold,design:.rounded))
    Text("رفع الملف الأصلي مباشرة عبر TikTok API").foregroundStyle(.secondary)
    card { Label("الفيديو",systemImage:"film.stack").font(.headline); PhotosPicker(selection:$pick,matching:.videos){ HStack{Image(systemName:movie==nil ? "plus":"checkmark.circle.fill");Text(loading ? "جاري تجهيز الملف…":movie==nil ? "اختر فيديو من الصور":"تم اختيار الفيديو");Spacer()}.padding().background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:16)) } }
    card { HStack{Label("Access Token",systemImage:"key.fill").font(.headline);Spacer();Button(show ? "إخفاء":"إظهار"){show.toggle()}}; if show{TextField("act....",text:$token)}else{SecureField("act....",text:$token)}; Text("يلزم token بصلاحية video.upload").font(.caption).foregroundStyle(.secondary) }
    card { status; Button{if let movie{Task{await up.upload(movie.url,token:token)}}}label:{HStack{Spacer();Image(systemName:"paperplane.fill");Text("ارفع إلى TikTok");Spacer()}.padding(10).font(.headline)}.buttonStyle(.borderedProminent).tint(.cyan).disabled(movie==nil || token.isEmpty || busy) }
    Text("لا يعيد التطبيق ترميز الفيديو أو ضغطه قبل الرفع؛ يرسل بايتات الملف نفسه. TikTok قد يعالج أو يعيد ترميز الفيديو بعد الاستلام.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
   }.padding(20) }
  }.preferredColorScheme(.dark) }.onChange(of:pick){_,v in guard let v else{return};Task{loading=true;movie=try? await v.loadTransferable(type:Movie.self);loading=false;up.state = .idle}}
 }
 @ViewBuilder var status:some View { switch up.state { case .idle:Text("جاهز").foregroundStyle(.secondary);case .preparing:ProgressView("بدء جلسة الرفع…");case .uploading(let p):VStack{ProgressView(value:p);Text("\(Int(p*100))%").font(.caption).monospacedDigit()};case .sent:Label("تم الإرسال — افتح إشعار TikTok لإكمال النشر",systemImage:"checkmark.seal.fill").foregroundStyle(.green);case .failed(let e):Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) } }
 func card<C:View>(@ViewBuilder _ c:()->C)->some View { VStack(alignment:.leading,spacing:12){c()}.padding(18).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:24)).overlay(RoundedRectangle(cornerRadius:24).stroke(.white.opacity(0.08))) }
}
