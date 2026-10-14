import CoreGraphics

// Adapted from LingDong-/skeleton-tracing, Swift implementation.
// Upstream commit: f5dd65e2389f9311dd3c24b9a83bd852c28c49e9.
// Changes: namespace/API isolation; demo and upstream thinning removed;
// empty-result sentinels made safe; 3x3 convolution top-right index corrected.
// Single-ended chunks retain real skeleton terminals instead of their center.
// Raster thinning and image segmentation are handled by ImageProcessor.
/*
MIT License

Copyright (c) 2020 Lingdong Huang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
enum SkeletonTracing {
    private static let HORIZONTAL = 1
    private static let VERTICAL = 2

    static func polylines(mask: [Bool], width: Int, height: Int) -> [[CGPoint]] {
        guard width >= 3, height >= 3, width <= 1_000_000 / height,
              mask.count == width * height, mask.contains(true) else { return [] }
        var pixels = mask.map { UInt8($0 ? 1 : 0) }
        let result = traceSkeleton(im: &pixels, W: width, H: height,
                                   x: 0, y: 0, w: width, h: height, csize: 6, maxIter: 128)
        return result.compactMap { chain in
            guard chain.count >= 2, chain.allSatisfy({ $0.count == 2 &&
                $0[0] >= 0 && $0[0] < width && $0[1] >= 0 && $0[1] < height }) else { return nil }
            var points: [CGPoint] = []
            for pair in chain {
                let p = CGPoint(x: Double(pair[0]) + 0.5, y: Double(pair[1]) + 0.5)
                if points.last != p { points.append(p) }
            }
            return points.count >= 2 ? points : nil
        }
    }

    private static func notEmpty(im : inout [UInt8], W : Int, H : Int, x : Int, y : Int, w : Int, h : Int) -> Bool {
      for i in y..<y+h {
        for j in x..<x+w {
          if (im[i*W+j] != 0){
            return true;
          }
        }
      }
      return false;
    }


    /**merge ith fragment of second chunk to first chunk
     * @param c0   fragments from  first  chunk
     * @param c1i  ith fragment of second chunk
     * @param sx   (x or y) coordinate of the seam
     * @param isv  is vertical, not horizontal?
     * @param mode 2-bit flag,
     *             MSB = is matching the left (not right) end of the fragment from first  chunk
     *             LSB = is matching the right (not left) end of the fragment from second chunk
     * @return     matching successful?
     */
    private static func mergeImpl(c0 : inout [[[Int]]], c1 : inout [[[Int]]], i : Int, sx : Int, isv : Bool, mode : Int) -> Bool {
        let b0 : Bool = (mode >> 1 & 1)>0; // match c0 left
        let b1 : Bool = (mode >> 0 & 1)>0; // match c1 left
        var mj = -1;
        var md = 4;
        let p1 = c1[i][b1 ? 0 : c1[i].count-1]
        if (abs(p1[isv ? 1 : 0]-sx)>0){
            return false;
        }
        for j in 0..<c0.count {
            let p0 = c0[j][b0 ? 0 : c0[j].count-1]
            if (abs(p0[isv ? 1 : 0]-sx)>1){
                continue;
            }
            let d = abs(p0[isv ? 0 : 1]-p1[isv ? 0 : 1])
            if (d < md){
                mj = j
                md = d
            }
        }
        if (mj != -1){
            if (b0 && b1){
                c1[i].reverse()
                c0[mj] = c1[i] + c0[mj]
            }else if (!b0 && b1){
                c0[mj]+=c1[i]
            }else if (b0 && !b1){
                c0[mj] = c1[i] + c0[mj]
            }else{
                c1[i].reverse()
                c0[mj] += c1[i]
            }
            c1.remove(at:i);
            return true;
        }
        return false;
    }
    /**merge fragments from two chunks
     * @param c0   fragments from first  chunk
     * @param c1   fragments from second chunk
     * @param sx   (x or y) coordinate of the seam
     * @param dr   merge direction, HORIZONTAL or VERTICAL?
     */
    private static func mergeFrags(c0 : inout [[[Int]]], c1 : inout [[[Int]]], sx : Int, dr : Int){
        for i in (0..<c1.count).reversed() {
            if (dr == HORIZONTAL){
                if (mergeImpl(c0:&c0,c1:&c1,i:i,sx:sx,isv:false,mode:1)){continue;}
                if (mergeImpl(c0:&c0,c1:&c1,i:i,sx:sx,isv:false,mode:3)){continue;}
                if (mergeImpl(c0:&c0,c1:&c1,i:i,sx:sx,isv:false,mode:0)){continue;}
                if (mergeImpl(c0:&c0,c1:&c1,i:i,sx:sx,isv:false,mode:2)){continue;}
            }else{
                if (mergeImpl(c0:&c0,c1:&c1,i:i,sx:sx,isv:true, mode:1)){continue;}
                if (mergeImpl(c0:&c0,c1:&c1,i:i,sx:sx,isv:true, mode:3)){continue;}
                if (mergeImpl(c0:&c0,c1:&c1,i:i,sx:sx,isv:true, mode:0)){continue;}
                if (mergeImpl(c0:&c0,c1:&c1,i:i,sx:sx,isv:true, mode:2)){continue;}
            }
        }
        c0 += c1;
    }

    /**recursive bottom: turn chunk into polyline fragments;
     * look around on 4 edges of the chunk, and identify the "outgoing" pixels;
     * add segments connecting these pixels to center of chunk;
     * apply heuristics to adjust center of chunk
     *
     * @param im   the bitmap image
     * @param W    width of  image
     * @param H    height of image
     * @param x    left of   chunk
     * @param y    top of    chunk
     * @param w    width of  chunk
     * @param h    height of chunk
     * @return     the polyline fragments
     */
    private static func chunkToFrags(im : inout [UInt8], W : Int, H : Int, x : Int, y : Int, w : Int, h : Int) -> [[[Int]]] {

        var frags : [[[Int]]] = [];
        var on : Bool = false;
        var li : Int = -1;
        var lj : Int = -1;

        for k in 0..<h+h+w+w-4 {
            var i : Int; var j : Int;
            if (k < w){
                i = y+0; j = x+k;
            }else if (k < w+h-1){
                i = y+k-w+1; j = x+w-1;
            }else if (k < w+h+w-2){
                i = y+h-1; j = x+w-(k-w-h+3);
            }else{
                i = y+h-(k-w-h-w+4); j = x+0;
            }
            if (im[i*W+j] > 0){ // found an outgoing pixel
                if (!on){       // left side of stroke
                    on = true;
                    frags.append([[j,i],[x+w/2,y+h/2]])
                }
            }else{
                if (on){ // right side of stroke, average to get center of stroke
                    frags[frags.count-1][0][0] = (frags[frags.count-1][0][0]+lj)/2
                    frags[frags.count-1][0][1] = (frags[frags.count-1][0][1]+li)/2
                    on = false
                }
            }
            li = i;
            lj = j;
        }

        if frags.count == 1 {
            // Upstream uses the chunk center for a dangling fragment. That
            // shortens open strokes by several pixels. If a true terminal is
            // present in this chunk, preserve that measured endpoint instead.
            let start = frags[0][0]
            let guessed = frags[0][1]
            var best: [Int]?
            var distance = Int.max
            for row in y..<(y + h) {
                for column in x..<(x + w) where im[row * W + column] > 0 {
                    var degree = 0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = column + dx, ny = row + dy
                            guard nx >= 0, nx < W, ny >= 0, ny < H,
                                  im[ny * W + nx] > 0 else { continue }
                            if dx != 0 && dy != 0 &&
                               (im[row * W + nx] > 0 || im[ny * W + column] > 0) { continue }
                            degree += 1
                        }
                    }
                    guard degree == 1, column != start[0] || row != start[1] else { continue }
                    let score = abs(column - guessed[0]) + abs(row - guessed[1])
                    if score < distance { best = [column, row]; distance = score }
                }
            }
            if let best { frags[0][1] = best }
        }
        if (frags.count == 2){  // probably just a line, connect them
            frags = [[frags[0][0], frags[1][0]]]

        }else if (frags.count > 2){ // it's a crossroad, guess the intersection

            var ms : Int = 0;
            var mi : Int = -1;
            var mj : Int = -1;
            // use convolution to find brightest blob
            for i in y+1..<y+h-1 {
                for j in x+1..<x+w-1 {
                    var s : Int = 0
                    s += Int(im[i*W-W+j-1])
                    s += Int(im[i*W-W+j])
                    s += Int(im[i*W-W+j+1])
                    s += Int(im[i*W+j-1])
                    s += Int(im[i*W+j])
                    s += Int(im[i*W+j+1])
                    s += Int(im[i*W+W+j-1])
                    s += Int(im[i*W+W+j])
                    s += Int(im[i*W+W+j+1])
                    if (s > ms){
                        mi = i;
                        mj = j;
                        ms = s;
                    }else if (s == ms && abs(j-(x+w/2))+abs(i-(y+h/2)) < abs(mj-(x+w/2))+abs(mi-(y+h/2))){
                        mi = i;
                        mj = j;
                        ms = s;
                    }
                }
            }
            if (mi != -1){
                for i in 0..<frags.count {
                    frags[i][1] = [mj,mi];
                }
            }
        }

        return frags;
    }

    /**Trace skeleton from thinning result.
     * Algorithm:
     * 1. if chunk size is small enough, reach recursive bottom and turn it into segments
     * 2. attempt to split the chunk into 2 smaller chunks, either horizontall or vertically;
     *    find the best "seam" to carve along, and avoid possible degenerate cases
     * 3. recurse on each chunk, and merge their segments
     *
     * @param im      the bitmap image
     * @param W       width of  image
     * @param H       height of image
     * @param x       left of   chunk
     * @param y       top of    chunk
     * @param w       width of  chunk
     * @param h       height of chunk
     * @param csize   chunk size
     * @param maxIter maximum number of iterations
     * @param rects   if not null, will be populated with chunk bounding boxes (e.g. for visualization)
     * @return        an array of polylines
     */
    private static func traceSkeleton(im : inout [UInt8], W : Int, H : Int, x : Int, y : Int, w : Int, h : Int, csize : Int, maxIter : Int) -> [[[Int]]]{

        if (maxIter == 0){
            return []
        }

        if (w <= csize && h <= csize){
            return chunkToFrags(im:&im,W:W,H:H,x:x,y:y,w:w,h:h)
        }

        var ms : Int = W+H; // number of white pixels on the seam, less the better
        var mi : Int = -1;
        var mj : Int = -1;
        if (h > csize){ // try splitting top and bottom
            for i in y+3..<y+h-3 {
                if (im[i*W+x]>0 || im[(i-1)*W+x]>0 || im[i*W+x+w-1]>0 || im[(i-1)*W+x+w-1]>0){
                    continue;
                }
                var s : Int = 0;
                for j in x..<x+w {
                    s += Int(im[i*W+j]);
                    s += Int(im[(i-1)*W+j]);
                }
                if (s < ms){
                    ms = s; mi = i;
                }else if (s == ms && abs(i-(y+h/2))<abs(mi-(y+h/2))){
                    // if there is a draw (very common), we want the seam to be near the middle
                    // to balance the divide and conquer tree
                    ms = s; mi = i;
                }
            }
        }

        if (w > csize){ // same as above, try splitting left and right
            for j in x+3..<x+w-3 {
                if (im[W*y+j]>0 || im[W*(y+h)-W+j]>0 || im[W*y+j-1]>0 || im[W*(y+h)-W+j-1]>0){
                    continue;
                }
                var s : Int = 0;
                for i in y..<y+h {
                    s += Int(im[i*W+j])
                    s += Int(im[i*W+j-1])
                }
                if (s < ms){
                    ms = s;
                    mi = -1; // horizontal seam is defeated
                    mj = j;
                }else if (s == ms && abs(j-(x+w/2))<abs(mj-(x+w/2))){
                    ms = s;
                    mi = -1;
                    mj = j;
                }
            }
        }

        var L0 = -1; var L1 = -1; var L2 = -1; var L3 = -1;
        var R0 = -1; var R1 = -1; var R2 = -1; var R3 = -1;
        var dr : Int = 0;
        var sx : Int = 0;

        if (h > csize && mi != -1){ // split top and bottom
            L0 = x; L1 = y;  L2 = w; L3 = mi-y;
            R0 = x; R1 = mi; R2 = w; R3 = y+h-mi;
            dr = VERTICAL;
            sx = mi;
        }else if (w > csize && mj != -1){
            L0 = x; L1 = y; L2 = mj-x;  L3 = h;
            R0 = mj;R1 = y; R2 = x+w-mj;R3 = h;
            dr = HORIZONTAL;
            sx = mj;
        }

        var aL = false;
        var aR = false;
        if (dr != 0 && notEmpty(im:&im,W:W,H:H,x:L0,y:L1,w:L2,h:L3)){
            aL = true;
        }
        if (dr != 0 && notEmpty(im:&im,W:W,H:H,x:R0,y:R1,w:R2,h:R3)){
            aR = true;
        }

        if (aL && aR){
            var frags = traceSkeleton(im:&im,W:W,H:H,x:L0,y:L1,w:L2,h:L3,csize:csize,maxIter:maxIter-1)
            var f = traceSkeleton(im:&im,W:W,H:H,x:R0,y:R1,w:R2,h:R3,csize:csize,maxIter:maxIter-1)
            mergeFrags(c0:&frags, c1:&f, sx:sx, dr:dr)
            return frags
        }else if (aL){
            return traceSkeleton(im:&im,W:W,H:H,x:L0,y:L1,w:L2,h:L3,csize:csize,maxIter:maxIter-1)
        }else if (aR){
            return traceSkeleton(im:&im,W:W,H:H,x:R0,y:R1,w:R2,h:R3,csize:csize,maxIter:maxIter-1)
        }

        if (mi == -1 && mj == -1){
            return chunkToFrags(im:&im,W:W,H:H,x:x,y:y,w:w,h:h)
        }

        return []
    }

}
