import Foundation
import CoreML
import CoreImage
import CoreGraphics

final class RealESRGANEngine {
    enum ModelKind:String { case x2plus="RealESRGAN_x2plus_522_fp16", x4plus="RealESRGAN_x4plus_522_fp16", general="RealESRGAN_general_522_fp16", animevideo="RealESRGAN_animevideo_522_fp16" }
    private let model:MLModel
    private let inferenceLock = NSLock()
    private let inputName:String
    private let outputName:String
    private let scale:Int
    private let ci=CIContext(options:[.cacheIntermediates:false])
    private let modelSide=522, tileSide=512, prePad=10

    init(kind:ModelKind) throws {
        guard let url=Bundle.main.url(forResource:kind.rawValue,withExtension:"mlmodelc") else {
            throw NSError(domain:"VideoLabAI",code:10,userInfo:[NSLocalizedDescriptionKey:"AI model missing: \(kind.rawValue)"])
        }
        let config=MLModelConfiguration();config.computeUnits = .all
        model=try MLModel(contentsOf:url,configuration:config)
        guard let i=model.modelDescription.inputDescriptionsByName.keys.first,
              let o=model.modelDescription.outputDescriptionsByName.keys.first else {
            throw NSError(domain:"VideoLabAI",code:11,userInfo:[NSLocalizedDescriptionKey:"Invalid Core ML model"])
        }
        inputName=i;outputName=o;scale = kind == .x2plus ? 2:4
    }

    func upscale(_ source:CIImage,target:CGSize) throws -> CIImage {
        inferenceLock.lock(); defer { inferenceLock.unlock() }
        let finite = source.extent
        guard finite.width.isFinite, finite.height.isFinite, finite.width > 0, finite.height > 0 else { throw NSError(domain:"VideoLabAI",code:12,userInfo:[NSLocalizedDescriptionKey:"Invalid video frame extent"]) }
        let src=source.cropped(to:finite)
        let w=Int(src.extent.width), h=Int(src.extent.height)
        let outW=w*scale,outH=h*scale
        guard let cs=CGColorSpace(name:CGColorSpace.sRGB) else { return source }
        var canvas=[UInt8](repeating:0,count:outW*outH*4)
        for y in stride(from:0,to:h,by:tileSide) {
            for x in stride(from:0,to:w,by:tileSide) {
                let tw=min(tileSide,w-x), th=min(tileSide,h-y)
                let crop=src.cropped(to:CGRect(x:x,y:y,width:tw,height:th))
                var inputPixels=[UInt8](repeating:0,count:modelSide*modelSide*4)
                ci.render(crop.transformed(by:CGAffineTransform(translationX:-CGFloat(x),y:-CGFloat(y))),
                          toBitmap:&inputPixels,rowBytes:modelSide*4,bounds:CGRect(x:0,y:0,width:modelSide,height:modelSide),format:.RGBA8,colorSpace:cs)
                let a=try MLMultiArray(shape:[1,3,NSNumber(value:modelSide),NSNumber(value:modelSide)],dataType:.float32)
                let ptr=a.dataPointer.bindMemory(to:Float32.self,capacity:3*modelSide*modelSide)
                let plane=modelSide*modelSide
                for py in 0..<modelSide { for px in 0..<modelSide {
                    let p=(py*modelSide+px)*4, q=py*modelSide+px
                    ptr[q]=Float32(inputPixels[p])/255
                    ptr[plane+q]=Float32(inputPixels[p+1])/255
                    ptr[2*plane+q]=Float32(inputPixels[p+2])/255
                }}
                let provider=try MLDictionaryFeatureProvider(dictionary:[inputName:MLFeatureValue(multiArray:a)])
                let prediction=try model.prediction(from:provider)
                guard let out=prediction.featureValue(for:outputName)?.multiArrayValue else { continue }
                let op=out.dataPointer.bindMemory(to:Float32.self,capacity:out.count)
                let full=modelSide*scale, oplane=full*full
                let copyW=tw*scale,copyH=th*scale
                for oy in 0..<copyH { for ox in 0..<copyW {
                    let si=oy*full+ox, dx=x*scale+ox,dy=y*scale+oy,di=(dy*outW+dx)*4
                    canvas[di]=UInt8(clamping:Int(max(0,min(1,op[si]))*255))
                    canvas[di+1]=UInt8(clamping:Int(max(0,min(1,op[oplane+si]))*255))
                    canvas[di+2]=UInt8(clamping:Int(max(0,min(1,op[2*oplane+si]))*255));canvas[di+3]=255
                }}
            }
        }
        guard let ctx=CGContext(data:&canvas,width:outW,height:outH,bitsPerComponent:8,bytesPerRow:outW*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let cg=ctx.makeImage() else{return source}
        var result=CIImage(cgImage:cg)
        if CGFloat(outW) != target.width || CGFloat(outH) != target.height {
            result=result.transformed(by:CGAffineTransform(scaleX:target.width/CGFloat(outW),y:target.height/CGFloat(outH)))
        }
        return result
    }
}
