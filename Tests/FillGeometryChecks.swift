import AppKit
@main struct FillChecks {
    enum Failure: Error { case check(String) }
    static func check(_ value: Bool, _ why: String) throws { if !value { throw Failure.check(why) } }
    static func fixture(_ f: (Double,Double)->Bool) -> CGImage {
        let n=360
        let v=(0..<n*n).map { i in UInt8(f((Double(i%n)+0.5)/3,(Double(i/n)+0.5)/3) ? 0:255) }
        let p=CGDataProvider(data:Data(v) as CFData)!
        return CGImage(width:n,height:n,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:n,
            space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:p,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    static func pixels(_ im:CGImage)->[UInt8] {
        let c=CGContext(data:nil,width:im.width,height:im.height,bitsPerComponent:8,bytesPerRow:im.width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
        c.draw(im,in:CGRect(x:0,y:0,width:im.width,height:im.height))
        return Array(UnsafeBufferPointer(start:c.data!.assumingMemoryBound(to:UInt8.self),count:im.width*im.height))
    }
    static func main() throws {
        setbuf(stdout,nil)
        let shapes:[(String,(Double,Double)->Bool,(Double,Double)->Bool,(Double,Double)->Bool)] = [
            ("disk", { hypot($0-60,$1-60)<35 }, { hypot($0-60,$1-60)<32 }, {hypot($0-60,$1-60)>38}),
            ("donut", { let d=hypot($0-60,$1-60);return d<38&&d>20 },{ let d=hypot($0-60,$1-60);return d<35&&d>23 },{hypot($0-60,$1-60)<17}),
            ("U slit", {x,y in x>20&&x<100&&y>20&&y<100 && !(x>48&&x<72&&y<80)},
                {x,y in x>23&&x<97&&y>23&&y<97 && !(x>45&&x<75&&y<83)},
                {x,y in x>51&&x<69&&y>23&&y<77}),
            ("separated blocks",{x,y in y>20&&y<100&&((x>20&&x<59)||(x>61&&x<100))},
                {x,y in y>23&&y<97&&((x>23&&x<56)||(x>64&&x<97))},
                {x,y in y>23&&y<97&&x>59.2&&x<60.8}),
            ("variable band",{x,y in let r=hypot(x-60,y-60);let w=2+5*(y/120);return r<35&&r>35-w},
                {x,y in let r=hypot(x-60,y-60);let w=2+5*(y/120);return r<33.8&&r>36.2-w},
                {x,y in hypot(x-60,y-60)<25})
        ]
        let s=ProcessingSettings(lineWidth:1,minimumMovement:8,canvasSize:CGSize(width:124,height:124),backingScale:2,minimumSpacingX:2.25,minimumSpacingY:2.25,endExtension:0.5)
        for (name,f,inside,outside) in shapes {
            let im=fixture(f)
            let p=try ImageProcessor.makePlan(image:im,mode:.solid,settings:s)
            let v=pixels(p.preview)
            var ink=0.0,paper=0.0,ni=0,no=0
            for y in 0..<p.preview.height { for x in 0..<p.preview.width {
                let px=(Double(x)+0.5)/2-2,py=(Double(y)+0.5)/2-2
                if inside(px,py) { ink += 1-Double(v[y*p.preview.width+x])/255;ni += 1 }
                if outside(px,py) { paper += Double(v[y*p.preview.width+x])/255;no += 1 }
            }}
            print(name,"strokes",p.strokes.count,"points",p.pointCount,"ink",ink/Double(ni),"paper",paper/Double(no))
            try check(ink/Double(ni)>0.97,name+" interior fill incomplete")
            try check(paper/Double(no)>0.995,name+" hole or slit crossed")
            for path in p.strokes {
                let length=zip(path.points,path.points.dropFirst()).reduce(0.0){$0+hypot($1.1.x-$1.0.x,$1.1.y-$1.0.y)}
                try check(length+1e-6>=8,name+" independent stroke too short")
                for q in path.points {try check(q.x>=2&&q.y>=2&&q.x<=122&&q.y<=122,name+" path escaped safety")}
            }
            var other=s;other.backingScale=1
            let same=try ImageProcessor.makePlan(image:im,mode:.solid,settings:other)
            try check(p.strokes.map(\.points)==same.strokes.map(\.points),"Retina changed fill geometry")
        }
        let allBlack=try ImageProcessor.makePlan(image:fixture { _,_ in true },mode:.solid,settings:s)
        let blackPixels=pixels(allBlack.preview)
        var blackInk=0.0,blackCount=0
        for y in 40..<200 {for x in 40..<200 {
            blackInk += 1-Double(blackPixels[y*allBlack.preview.width+x])/255;blackCount += 1
        }}
        try check(!allBlack.strokes.isEmpty&&blackInk/Double(blackCount)>0.98,"Uniform black input lost its full region")
        let allWhite=try ImageProcessor.makePlan(image:fixture { _,_ in false },mode:.solid,settings:s)
        try check(allWhite.strokes.isEmpty&&pixels(allWhite.preview).allSatisfy{$0==255},"Paper acquired fill")
        let dot=try ImageProcessor.makePlan(image:fixture { x,y in hypot(x-60,y-60)<0.4 },mode:.solid,settings:s)
        try check(dot.strokes.isEmpty,"Sub-pen-width isolated dot expanded into white paper")
        print("PASS uniform black / pure paper / tiny independent ink")
        print("PASS solid coverage / hole / concavity / separated areas / variable width / independent length / physical safety / Retina")
    }
}
