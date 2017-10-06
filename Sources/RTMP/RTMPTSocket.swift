import Foundation

final class RTMPTSocket: NSObject, RTMPSocketCompatible {
    static let contentType:String = "application/x-fcs"

    var timeout:Int64 = 0
    var chunkSizeC:Int = RTMPChunk.defaultSize
    var chunkSizeS:Int = RTMPChunk.defaultSize
    var inputBuffer:Data = Data()
    var securityLevel:StreamSocketSecurityLevel = .none
    weak var delegate:RTMPSocketDelegate? = nil
    var connected:Bool = false {
        didSet {
            if (connected) {
                handshake.timestamp = Date().timeIntervalSince1970
                OSAtomicAdd64(Int64(handshake.c0c1packet.count), &self.queueBytesOut)
                doOutput(data: handshake.c0c1packet)
                readyState = .versionSent
                return
            }
            timer = nil
            readyState = .closed
            for event in events {
                delegate?.dispatch(event: event)
            }
            events.removeAll()
        }
    }

    var timestamp:TimeInterval {
        return handshake.timestamp
    }

    var readyState:RTMPSocket.ReadyState = .uninitialized {
        didSet {
            delegate?.didSetReadyState(readyState)
        }
    }

    fileprivate(set) var totalBytesIn:Int64 = 0
    fileprivate(set) var totalBytesOut:Int64 = 0
    fileprivate(set) var totalBytesDropped:Int64 = 0
    fileprivate(set) var queueBytesOut:Int64 = 0
    fileprivate var timer:Timer? {
        didSet {
            if let oldValue:Timer = oldValue {
                oldValue.invalidate()
            }
            if let timer:Timer = timer {
                RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
            }
        }
    }

    private var delay:UInt8 = 1
    private var index:Int64 = 0
    private var events:[Event] = []
    private var baseURL:URL!
    private var session:URLSession!
    private var request:URLRequest!
    private var c2packet:Data = Data()
    private var handshake:RTMPHandshake = RTMPHandshake()
    private let outputQueue:DispatchQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.RTMPTSocket.output")
    private var connectionID:String?
    private var isRequesting:Bool = false
    private var outputBuffer:Data = Data()
    private var outputRTMPQueue:[[Data]] = []
    private var lastResponse:Date = Date()
    private var isRetryingRequest:Bool = true

    private let maxChunks = 30

    private var requestTask:URLSessionUploadTask?
    private var requestTaskTimer:Timer?

    override init() {
        super.init()
    }

    func connect(withName:String, port:Int) {
        let config:URLSessionConfiguration = URLSessionConfiguration.default
        config.httpShouldUsePipelining = true
        config.httpAdditionalHeaders = [
            "Content-Type": RTMPTSocket.contentType,
            "User-Agent": "Shockwave Flash",
        ]
        let scheme:String = securityLevel == .none ? "http" : "https"
        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
        baseURL = URL(string: "\(scheme)://\(withName):\(port)")!
        doRequest("/fcs/ident2", Data([0x00]), didIdent2)
        timer = Timer(timeInterval: 0.1, target: self, selector: #selector(RTMPTSocket.on(timer:)), userInfo: nil, repeats: true)
    }

    private func addChunk(rtmpChunk:RTMPChunk) {
        if self.outputRTMPQueue.count == 0 {
            self.outputRTMPQueue.append([])
        }
        if self.outputRTMPQueue.last!.count >= maxChunks {
            self.outputRTMPQueue.append([])
        }
        let chunks:[Data] = rtmpChunk.split(chunkSizeS)
        for chunk:Data in chunks {
            OSAtomicAdd64(Int64(chunk.count), &self.queueBytesOut)
            self.outputRTMPQueue[self.outputRTMPQueue.count - 1].append(chunk)
        }
    }

    private func getBuffer() -> Data {
        var result:Data = Data()
        for chunk:Data in self.outputRTMPQueue.first ?? [] {
            result += chunk;
        }
        return result
    }


    @discardableResult
    func doOutput(chunk:RTMPChunk, locked:UnsafeMutablePointer<UInt32>? = nil) -> Int {
        guard let connectionID:String = connectionID, connected else {
            return 0
        }
        outputQueue.sync {
            addChunk(rtmpChunk: chunk)
            logger.trace("doOutput \(index) \(self.outputRTMPQueue.count) \((self.outputRTMPQueue.first ?? []).count)")
            if !self.isRequesting {
                self.doOutput(data: getBuffer())
                self.outputRTMPQueue.removeFirst()
            }
        }
        if (locked != nil) {
            OSAtomicAnd32Barrier(0, locked!)
        }
        return chunk.size
    }

    func close(isDisconnected:Bool) {
        deinitConnection(isDisconnected: isDisconnected)
    }

    func deinitConnection(isDisconnected:Bool) {
        if (isDisconnected) {
            let data:ASObject = (readyState == .handshakeDone) ?
                    RTMPConnection.Code.connectClosed.data("") : RTMPConnection.Code.connectFailed.data("")
            events.append(Event(type: Event.RTMP_STATUS, bubbles: false, data: data))
        }
        guard let connectionID:String = connectionID else {
            return
        }
        doRequest("/close/\(connectionID)", Data(), didClose)
    }

    private func listen(data:Data?, response:URLResponse?, error:Error?) {
        logger.trace("listen")

        lastResponse = Date()

        if (logger.isEnabledFor(level: .trace)) {
            logger.trace("\(String(describing: data)):\(String(describing: response)):\(String(describing: error))")
        }

        doNextRequest()

        if let error:Error = error {
            logger.error("\(error)")

            return
        }

        guard
                let response:HTTPURLResponse = response as? HTTPURLResponse,
                let contentType:String = response.allHeaderFields["Content-Type"] as? String,
                let data:Data = data, contentType == RTMPTSocket.contentType else {
            return
        }
        
        if response.statusCode != 200 {
            self.deinitConnection(isDisconnected: false)
            self.delegate?.dispatch(Event.IO_ERROR, bubbles: false, data: nil)
            logger.warn("connection failed with status code: \(response.statusCode)")
            return
        }

        var buffer:[UInt8] = data.bytes
        OSAtomicAdd64(Int64(buffer.count), &totalBytesIn)
        delay = buffer.remove(at: 0)
        inputBuffer.append(contentsOf: buffer)

        switch readyState {
        case .versionSent:
            if (inputBuffer.count < RTMPHandshake.sigSize + 1) {
                break
            }
            c2packet = handshake.c2packet(inputBuffer)
            inputBuffer.removeSubrange(0...RTMPHandshake.sigSize)
            readyState = .ackSent
            fallthrough
        case .ackSent:
            if (inputBuffer.count < RTMPHandshake.sigSize) {
                break
            }
            inputBuffer.removeAll()
            readyState = .handshakeDone
        case .handshakeDone:
            if (inputBuffer.isEmpty){
                break
            }
            let data:Data = inputBuffer
            inputBuffer.removeAll()
            delegate?.listen(data)
        default:
            break
        }

    }

    private func doNextRequest() {
        logger.trace("do next request")
        if (!self.connected) {
            return
        }

        self.outputQueue.sync {
            let buffer:Data = getBuffer()
            if (buffer.isEmpty) {
                self.isRequesting = false
            } else {
                self.doOutput(data: buffer)
                self.outputRTMPQueue.removeFirst()
            }
        }
    }

    func setTimeout(delay:TimeInterval, block:@escaping ()->Void) -> Timer {
        return Timer.scheduledTimer(timeInterval: delay, target: BlockOperation(block: block), selector: #selector(Operation.main), userInfo: nil, repeats: false)
    }

    private func didIdent2(data:Data?, response:URLResponse?, error:Error?) {
        if let error:Error = error {
            logger.error("\(error)")
        }
        doRequest("/open/1", Data([0x00]), didOpen)
        if (logger.isEnabledFor(level: .trace)) {
            logger.trace("\(String(describing: data?.bytes)):\(String(describing: response))")
        }
    }

    private func didOpen(data:Data?, response:URLResponse?, error:Error?) {
        if let error:Error = error {
            logger.error("\(error)")
        }
        guard let data:Data = data else {
            return
        }
        connectionID = String(data: data, encoding: String.Encoding.utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        doRequest("/idle/\(connectionID!)/0", Data([0x00]), didIdle0)
        if (logger.isEnabledFor(level: .trace)) {
            logger.trace("\(data.bytes):\(String(describing: response))")
        }
    }

    private func didIdle0(data:Data?, response:URLResponse?, error:Error?) {
        if let error:Error = error {
            logger.error("\(error)")
        }
        connected = true
        if (logger.isEnabledFor(level: .trace)) {
            logger.trace("\(String(describing: data?.bytes)):\(String(describing: response))")
        }
    }

    private func didClose(data:Data?, response:URLResponse?, error:Error?) {
        if let error:Error = error {
            logger.error("\(error)")
        }
        connected = false
        if (logger.isEnabledFor(level: .trace)) {
            logger.trace("\(String(describing: data?.bytes)):\(String(describing: response))")
        }
    }

    private func idle() {
        guard let connectionID:String = connectionID, connected else {
            return
        }
        outputQueue.sync {
            let index: Int64 = OSAtomicIncrement64(&self.index)
            doRequest("/idle/\(connectionID)/\(index)", Data([0x00]), didIdle)
        }
    }

    private func didIdle(data:Data?, response:URLResponse?, error:Error?) {
        listen(data: data, response: response, error: error)
    }

    @objc private func on(timer:Timer) {
        guard (Double(delay) / 10) < abs(lastResponse.timeIntervalSinceNow), !isRequesting else {
            return
        }
        idle()
    }

    @discardableResult
    final private func doOutput(data:Data) -> Int {
        guard let connectionID:String = connectionID, connected else {
            return 0
        }
        let index:Int64 = OSAtomicIncrement64(&self.index)
        doRequest("/send/\(connectionID)/\(index)", c2packet + data, {
            (receivedData:Data?, response:URLResponse?, error:Error?) in
            logger.trace("do request done")
            OSAtomicAdd64(-Int64(data.count), &self.queueBytesOut)
            self.listen(data: receivedData, response: response, error: error)
        })
        c2packet.removeAll()
        return data.count
    }

    private var timeSent = Date()
    private var firstRequestTimeSent:Date?

    private func doRequest(_ pathComponent: String,_ data:Data,_ completionHandler: @escaping ((Data?, URLResponse?, Error?) -> Void), timeout: Bool = true) {
        if (firstRequestTimeSent == nil) {
            firstRequestTimeSent = Date()
        }

        isRequesting = true
        request = URLRequest(url: baseURL.appendingPathComponent(pathComponent))
        request.httpMethod = "POST"
        requestTask = session.uploadTask(with: request, from: data, completionHandler: {
            (requestData:Data?, response:URLResponse?, error:Error?) in

            logger.trace("upload task complete ")
            if (self.index > 1) {
                self.requestTaskTimer!.invalidate()
            }
            
            if let _:Error = error {
                if self.isRetryingRequest == false {
                    logger.trace("upload task error, retrying?")
                    self.isRetryingRequest = true;
                    OSAtomicAdd64(Int64(data.count), &self.queueBytesOut)
                    return self.doRequest(pathComponent, data, completionHandler)
                } else {
                    logger.trace("dropping due to error")
                    OSAtomicAdd64(Int64(data.count), &self.totalBytesDropped)
                }
            }
            self.isRetryingRequest = false;
            if (pathComponent == "/send/" + (self.connectionID ?? "") + "/1") {
                logger.trace("handshake: " + String(describing: self.firstRequestTimeSent?.timeIntervalSinceNow));
            }
            completionHandler(requestData, response, error)
        })
        timeSent = Date()
        requestTask!.resume()

        logger.trace("doRequest \(index) \(data.count)")
        if (index > 1) {
            requestTaskTimer = setTimeout(delay: 3, block: {
                logger.trace("dropping rtmpchunk due to timeout \(self.index)")
                OSAtomicIncrement64(&self.index)
                OSAtomicAdd64(Int64(data.count), &self.totalBytesDropped)
                self.requestTask!.cancel()
                completionHandler(nil, nil, nil)
            })
        }
        if (logger.isEnabledFor(level: .trace)) {
            logger.trace("\(self.request)")
        }
    }
}

// MARK: -
extension RTMPTSocket: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        OSAtomicAdd64(bytesSent, &totalBytesOut)
    }
}
