#cython: boundscheck=False, wraparound=False

from libcpp.string cimport string
from libcpp.vector cimport vector
from libcpp cimport bool
from cython.operator cimport dereference as drf
from cython cimport sizeof
cimport c_openni2
include "config.pxi"

cimport numpy as np
import numpy as np
import sys
from struct import pack, unpack, calcsize

pixelFormats = {
    b"rgb": c_openni2.PIXEL_FORMAT_RGB888,
    b"yuv422": c_openni2.PIXEL_FORMAT_YUV422,
    b"gray16": c_openni2.PIXEL_FORMAT_GRAY16,
    b"depth1mm": c_openni2.PIXEL_FORMAT_DEPTH_1_MM,
    b"depth100um": c_openni2.PIXEL_FORMAT_DEPTH_100_UM,
}

pixelFormatsReverse = dict([[v, k] for k, v in pixelFormats.items()])

class OpenNIException(Exception):
    pass


def warning(*args):
    sys.stderr.write("Warning: " + ' '.join(map(str, args)) + '\n')

def error(*args):
    #sys.stderr.write(' '.join(map(str,args)) + '\n')
    raise OpenNIException(' '.join(map(str, args)))


def initialize():
    ret = c_openni2.initialize()
    if ret !=  c_openni2.STATUS_OK:
        raise RuntimeError("Failed to initialize OpenNi2, return code was {}".format(ret))
    return ret


def enumerateDevices():
    cdef c_openni2.Array[c_openni2.DeviceInfo] c_devices
    c_openni2.enumerateDevices(&c_devices)
    devices = []
    for i in range(c_devices.getSize()):
        d = {}
        d['name'] = c_devices[i].getName()
        d['uri'] = c_devices[i].getUri()
        d['vendor'] = c_devices[i].getVendor()
        d['usbVendorId'] = c_devices[i].getUsbVendorId()
        d['usbProductId'] = c_devices[i].getUsbProductId()
        devices.append(d)
    return devices


cdef class Device(object):

    cdef c_openni2.Device _device
    cdef const char* _uri
    cdef vector[c_openni2.VideoStream*] _streams

    def __dealloc__(self):
        if self._device.isValid():
            for _stream in self._streams:
                if _stream.isValid():
                    _stream.stop()
                    _stream.destroy()
            self._streams.clear()
        
            self._device.close()

    def __init__(self, uri):
        self._uri = uri

    def open(self, syncFrames=None):
        with nogil:
            self._device.open(self._uri)
        if syncFrames is not None:
            self.setDepthColorSyncEnabled(syncFrames)

    def setDepthColorSyncEnabled(self, on=True):
        status = self._device.setDepthColorSyncEnabled(on)
        if status != c_openni2.STATUS_OK:
            error("Couldn't set Depth and Color syncrhonization to %s" % on)
            return False
        return True

    def getDepthColorSyncEnabled(self):
        return self._device.getDepthColorSyncEnabled()

    def setImageRegistrationMode(self, mode):
        if mode == "off":
            c_mode = c_openni2.IMAGE_REGISTRATION_OFF
        elif mode == "depth_to_color":
            c_mode = c_openni2.IMAGE_REGISTRATION_DEPTH_TO_COLOR

        if self._device.isImageRegistrationModeSupported(c_mode):
            status = self._device.setImageRegistrationMode(c_mode)
            return status == c_openni2.STATUS_OK
        else:
            warning("ImageRegistrationMode %s isn't supported." % mode)
            return False

    def getImageRegistrationMode(self):
        mode = self._device.getImageRegistrationMode()
        if mode == c_openni2.IMAGE_REGISTRATION_OFF:
            return "off"
        elif mode == c_openni2.IMAGE_REGISTRATION_DEPTH_TO_COLOR:
            return "depth_to_color"

    def createStream(self, streamType, width=None, height=None, fps=None, format=None):
        if not self._device.isValid():
            error("Must open() the device before creating any streams.")

        stream = VideoStream()
        stream.create(self._device, streamType, width, height, fps, format)
        self._streams.push_back(&(stream._stream))
        return stream

    def getSerial(self):
        cdef int size = 1024
        cdef char serial[1024]
        propId = c_openni2.ONI_DEVICE_PROPERTY_SERIAL_NUMBER
        self._device.getProperty(propId, &serial, &size)
        return <bytes> serial

    def getSupportedVideoModes(self, sensorType):
        cdef const c_openni2.SensorInfo* _info
        if sensorType == "color":
            _info = self._device.getSensorInfo(c_openni2.SENSOR_COLOR)
        elif sensorType == "depth":
            _info = self._device.getSensorInfo(c_openni2.SENSOR_DEPTH)
        elif sensorType == "ir":
            _info = self._device.getSensorInfo(c_openni2.SENSOR_IR)
        else:
            return []
        cdef const c_openni2.Array[c_openni2.VideoMode]* _modes
        _modes = &(_info.getSupportedVideoModes())
        modes = []
        for i in range(_modes.getSize()):
            mode = drf(_modes)[i]
            pixelFormat = pixelFormatsReverse.get(mode.getPixelFormat(), "N/A")
            modes.append({"width": mode.getResolutionX(),
                          "height": mode.getResolutionY(),
                          "fps": mode.getFps(),
                          "pixelFormat": pixelFormat})
        return modes

    def close(self):
        if self._device.isValid():
            for _stream in self._streams:
                if _stream.isValid():
                    with nogil:
                        _stream.stop()
                    _stream.destroy()
            self._streams.clear()
            self._device.close()

class Frame(object):
    def __init__(self, data, metadata, sensorType):
        self.data = data
        self.metadata = metadata
        self.sensorType = sensorType


cdef class VideoStream(object):
    cdef c_openni2.VideoStream _stream
    cdef bytes _streamType
    cdef bytes _pixelFormat
    cdef int frameSize

    cdef readonly int width
    cdef readonly int height
    cdef readonly int fps

    def __dealloc__(self):
        if self._stream.isValid():
            self._stream.stop()
            self._stream.destroy()

    cdef create(self,
                c_openni2.Device& _device,
                streamType,
                width,
                height,
                fps,
                pixelFormat):

        cdef c_openni2.Status status

        self._streamType = streamType

        with nogil:
            if self._streamType == b"color":
                status = self._stream.create(_device, c_openni2.SENSOR_COLOR)
            elif self._streamType == b"depth":
                status = self._stream.create(_device, c_openni2.SENSOR_DEPTH)
            elif self._streamType == b"ir":
                status = self._stream.create(_device, c_openni2.SENSOR_IR)

        if status != c_openni2.STATUS_OK:
            error("Error opening %s stream." % self._streamType)

        cdef const c_openni2.SensorInfo* _info = &self._stream.getSensorInfo()

        cdef const c_openni2.Array[c_openni2.VideoMode]* _modes
        _modes = &(_info.getSupportedVideoModes())

        foundMode = False
        if self._streamType == b"color" and pixelFormat != b"rgb":
            if pixelFormat is None:
                pixelFormat = b"rgb"
            else:
                error("Only RGB currently supported for color streams.")
                self.destroy()
                return

        for i in range(_modes.getSize()):
            mode = drf(_modes)[i]
            if width is not None and width != mode.getResolutionX():
                continue
            else:
                chosenX = mode.getResolutionX()
            if height is not None and height != mode.getResolutionY():
                continue
            if fps is not None and fps != mode.getFps():
                continue
            if (pixelFormat is not None and
                pixelFormats[pixelFormat] != mode.getPixelFormat()):
                continue

            # Set the pixel format in case it was None
            pixelFormat = pixelFormatsReverse[mode.getPixelFormat()]

            if pixelFormat == b"rgb":
                pixelSize = sizeof(c_openni2.RGB888Pixel)
            elif pixelFormat == b"yuv422":
                pixelSize = sizeof(c_openni2.YUV422DoublePixel)
            elif pixelFormat == b"depth1mm":
                pixelSize = sizeof(c_openni2.DepthPixel)
            elif pixelFormat == b"depth100um":
                pixelSize = sizeof(c_openni2.DepthPixel)
            elif pixelFormat == b"gray16":
                pixelSize = sizeof(c_openni2.Grayscale16Pixel)

            self._pixelFormat = pixelFormat

            self.width = mode.getResolutionX()
            self.height = mode.getResolutionY()
            self.fps = mode.getFps()

            self.frameSize = self.width * self.height * pixelSize

            self._stream.setVideoMode(mode)

            foundMode = True

            break

        if not foundMode:
            error("Couldn't find supported mode for %s stream." % streamType)
            self.destroy()

    def start(self):
        cdef c_openni2.Status status
        with nogil:
            status = self._stream.start()
        if status != c_openni2.STATUS_OK:
            error("Error starting %s stream." % self._streamType)
            self.destroy()
        return status == c_openni2.STATUS_OK

    def readFrame(self):
        if not self._stream.isValid():
            error("Stream is invalid.")
            return None

        cdef c_openni2.VideoFrameRef _frame
        with nogil:
            self._stream.readFrame(&_frame)
        if not _frame.isValid():
            error("Invalid frame read.")
            return None

        if _frame.getDataSize() != self.frameSize:
            error("Read frame with wrong size. Got height: %d, width: %d"
                  % (_frame.getHeight(), _frame.getWidth()))
            return None

        metadata = {}
        metadata["timestamp"] = _frame.getTimestamp()
        metadata["frameIndex"] = _frame.getFrameIndex()

        cdef np.ndarray[np.uint8_t, ndim=3] _data3D
        cdef np.ndarray[np.uint16_t, ndim=2] _data2D

        if self._streamType == b"color":
            if self._pixelFormat == b"rgb":
                _data3D = np.empty((self.height, self.width, 3), dtype=np.uint8)
                self.convertRGBFrame(_frame, _data3D)
                return Frame(_data3D, metadata, self._streamType)
            else:
                error("Only RGB currently supported for color streams.")
                return None
        elif self._streamType == b"depth":
            _data2D = np.empty((self.height, self.width), dtype=np.uint16)
            self.convertDepthFrame(_frame, _data2D)
            return Frame(_data2D, metadata, self._streamType)
        elif self._streamType == b"ir":
            _data2D = np.empty((self.height, self.width), dtype=np.uint16)
            self.convertIRFrame(_frame, _data2D)
            return Frame(_data2D, metadata, self._streamType)

    cdef void convertRGBFrame(self, c_openni2.VideoFrameRef _frame, np.uint8_t[:,:,:] image) nogil:

        _imageData = <const c_openni2.RGB888Pixel*> _frame.getData()

        cdef int x, y, index

        cdef c_openni2.RGB888Pixel _pixel

        for y in range(self.height):
            for x in range(self.width):
                index = y*self.width + x
                _pixel = <const c_openni2.RGB888Pixel> _imageData[index]
                image[y, x, 0] = _pixel.r
                image[y, x, 1] = _pixel.g
                image[y, x, 2] = _pixel.b

    cdef void convertIRFrame(self, c_openni2.VideoFrameRef _frame, np.uint16_t[:,:] image) nogil:
        _imageData = <const c_openni2.Grayscale16Pixel*> _frame.getData()
        cdef int x, y
        cdef c_openni2.Grayscale16Pixel _pixel
        for y in range(self.height):
            for x in range(self.width):
                index = y*self.width + x
                _pixel = <const c_openni2.Grayscale16Pixel> _imageData[index]
                image[y, x] = _pixel

    cdef void convertDepthFrame(self, c_openni2.VideoFrameRef _frame, np.uint16_t[:,:] image) nogil:
        _imageData = <const c_openni2.DepthPixel*> _frame.getData()
        cdef int x, y
        for y in range(self.height):
            for x in range(self.width):
                image[y, x] = _imageData[y*self.width + x]

    def stop(self):
        with nogil:
            if self._stream.isValid():
                self._stream.stop()

    def destroy(self):
        if self._stream.isValid():
            with nogil:
                self._stream.stop()
            self._stream.destroy()

    def setMirroring(self, on=True):
        self._stream.setMirroringEnabled(on)

    def getMirroring(self):
        return self._stream.getMirroringEnabled()

    def getAutoExposureEnabled(self):
        curr_setting = self._stream.getCameraSettings()
        return curr_setting.getAutoExposureEnabled()

    def setAutoExposureEnabled(self, enabled=True):
        curr_setting = self._stream.getCameraSettings()
        curr_setting.setAutoExposureEnabled(enabled)

    def getExposure(self):
        curr_setting = self._stream.getCameraSettings()
        return curr_setting.getExposure()

    def setExposure(self, exposure):
        curr_setting = self._stream.getCameraSettings()
        curr_setting.setExposure(exposure)

    def getAutoWhiteBalanceEnabled(self):
        curr_setting = self._stream.getCameraSettings()
        return curr_setting.getAutoWhiteBalanceEnabled()

    def setAutoWhiteBalanceEnabled(self, enabled=True):
        curr_setting = self._stream.getCameraSettings()
        curr_setting.setAutoWhiteBalanceEnabled(enabled)

    def getGain(self):
        curr_setting = self._stream.getCameraSettings()
        return curr_setting.getGain()

    def setGain(self, gain):
        curr_setting = self._stream.getCameraSettings()
        curr_setting.setGain(gain)

    def getHorizontalFieldOfView(self):
      return self._stream.getHorizontalFieldOfView()

    def getVerticalFieldOfView(self):
      return self._stream.getVerticalFieldOfView()

    IF HAS_EMITTER_CONTROL == 1:
        cpdef setEmitterState(self, bool on=True):
            with nogil:
                if self._streamType == b"depth" or self._streamType == b"ir":
                    self._stream.setEmitterEnabled(on)

cdef _depthMapToPointCloudXYZ(np.ndarray[np.float_t, ndim=3] pointCloud,
                              np.ndarray[np.uint16_t, ndim=2] depthMap,
                              VideoStream depthStream):

    cdef int rows = depthMap.shape[0]
    cdef int cols = depthMap.shape[1]

    cdef int row, col

    cdef float worldX, worldY, worldZ

    for y in range(rows):
        for x in range(cols):
            c_openni2.convertDepthToWorld(depthStream._stream, x, y, depthMap[y,x],
                                          &worldX, &worldY, &worldZ)
            pointCloud[y,x,0] = worldX
            pointCloud[y,x,1] = -worldY
            pointCloud[y,x,2] = worldZ

cdef _depthMapToPointCloudXYZRGB(np.ndarray[np.float_t, ndim=3] pointCloud,
                              np.ndarray[np.uint16_t, ndim=2] depthMap,
                              np.ndarray[np.uint8_t, ndim=3] colorImage,
                              VideoStream depthStream):

    cdef int rows = depthMap.shape[0]
    cdef int cols = depthMap.shape[1]

    cdef int row, col

    cdef float worldX, worldY, worldZ

    for y in range(rows):
        for x in range(cols):
            c_openni2.convertDepthToWorld(depthStream._stream, x, y, depthMap[y,x],
                                          &worldX, &worldY, &worldZ)
            pointCloud[y,x,0] = worldX
            pointCloud[y,x,1] = -worldY
            pointCloud[y,x,2] = worldZ
            pointCloud[y,x,3] = colorImage[y,x,0]
            pointCloud[y,x,4] = colorImage[y,x,1]
            pointCloud[y,x,5] = colorImage[y,x,2]

cdef _depthMapToPointCloudXYZRGB_IR(np.ndarray[np.float_t, ndim=3] pointCloud,
                                    np.ndarray[np.uint16_t, ndim=2] depthMap,
                                    np.ndarray[np.uint16_t, ndim=2] irImage,
                                    VideoStream depthStream):

    cdef int rows = depthMap.shape[0]
    cdef int cols = depthMap.shape[1]

    cdef int row, col, x, y

    cdef float worldX, worldY, worldZ

    for y in range(rows):
        for x in range(cols):
            c_openni2.convertDepthToWorld(depthStream._stream, x, y, depthMap[y,x],
                                          &worldX, &worldY, &worldZ)
            pointCloud[y,x,0] = worldX
            pointCloud[y,x,1] = -worldY
            pointCloud[y,x,2] = worldZ
            pointCloud[y,x,3] = irImage[y,x]
            pointCloud[y,x,4] = irImage[y,x]
            pointCloud[y,x,5] = irImage[y,x]

def registerDepthMap(np.ndarray[np.uint16_t, ndim=2] depthMapIn, np.ndarray[np.uint8_t, ndim=3] colorImage, VideoStream depthStream, VideoStream colorStream):
  cdef int rows = depthMapIn.shape[0]
  cdef int cols = depthMapIn.shape[1]
  cdef int colorRows = colorImage.shape[0]
  cdef int colorCols = colorImage.shape[1]

  if colorCols != cols or colorRows != rows:
    error("Registration doesn't work if depth + color are of different shape")
    return None

  cdef int x, y, colorX, colorY
  cdef np.ndarray[np.uint16_t, ndim=2] depthMapOut = np.zeros((depthMapIn.shape[0], depthMapIn.shape[1]), dtype=np.uint16)

  for y in range(rows):
    for x in range(cols):
      colorX = -1
      colorY = -1
      c_openni2.convertDepthToColor(depthStream._stream, colorStream._stream, x, y, depthMapIn[y,x], &colorX, &colorY)
      if colorX > 0 and colorY > 0:
        depthMapOut[colorY, colorX] = depthMapIn[y, x]
 
  return depthMapOut

def getAnyDevice():
    deviceList = enumerateDevices()
    if not deviceList:
        raise RuntimeError("Node device found")
    return Device(deviceList[0]['uri'])

def depthMapToImage(image):
    return np.uint8(image / (np.max(image)*1.0/255))

def depthMapToPointCloud(depthMap, depthStream, colorImage=None):
    if colorImage is None:
        pointCloud = np.zeros((depthMap.shape[0], depthMap.shape[1], 3))
        _depthMapToPointCloudXYZ(pointCloud, depthMap, depthStream)
        return pointCloud
    else:
        if (colorImage.shape[0] == depthMap.shape[0] and
            colorImage.shape[1] == depthMap.shape[1]):
            pointCloud = np.zeros((depthMap.shape[0], depthMap.shape[1], 6))
            if len(colorImage.shape) == 3:
              _depthMapToPointCloudXYZRGB(pointCloud, depthMap, colorImage, depthStream)
            else:
              _depthMapToPointCloudXYZRGB_IR(pointCloud, depthMap, colorImage, depthStream)
            return pointCloud
        else:
            raise Exception("Depth and color images must have save dimensions.")

def writePCD(pointCloud, filename, ascii=False):
    with open(filename, 'wb') as f:
        height = pointCloud.shape[0]
        width = pointCloud.shape[1]
        f.write(b"# .PCD v.7 - Point Cloud Data file format\n")
        f.write(b"VERSION .7\n")
        if pointCloud.shape[2] == 3:
            f.write(b"FIELDS x y z\n")
            f.write(b"SIZE 4 4 4\n")
            f.write(b"TYPE F F F\n")
            f.write(b"COUNT 1 1 1\n")
        else:
            f.write(b"FIELDS x y z rgb\n")
            f.write(b"SIZE 4 4 4 4\n")
            f.write(b"TYPE F F F F\n")
            f.write(b"COUNT 1 1 1 1\n")
        f.write(b"WIDTH %d\n" % width)
        f.write(b"HEIGHT %d\n" % height)
        f.write(b"VIEWPOINT 0 0 0 1 0 0 0\n")
        f.write(b"POINTS %d\n" % (height * width))
        if ascii:
          f.write(b"DATA ascii\n")
          for row in range(height):
            for col in range(width):
                if pointCloud.shape[2]== 3:
                    f.write(b"%f %f %f\n" % tuple(pointCloud[row, col, :]))
                else:
                    f.write(b"%f %f %f" % tuple(pointCloud[row, col, :3]))
                    r = int(pointCloud[row, col, 3])
                    g = int(pointCloud[row, col, 4])
                    b = int(pointCloud[row, col, 5])
                    rgb_int = (r << 16) | (g << 8) | b
                    packed = pack('i', rgb_int)
                    rgb = unpack('f', packed)[0]
                    f.write(b" %.12e\n" % rgb)
        else:
          f.write(b"DATA binary\n")
          if pointCloud.shape[2] == 6:
              dt = np.dtype([('x', np.float32),
                             ('y', np.float32),
                             ('z', np.float32),
                             ('r', np.uint8),
                             ('g', np.uint8),
                             ('b', np.uint8),
                             ('I', np.uint8)])
              pointCloud_tmp = np.zeros((height*width), dtype=dt)
              for i, k in enumerate(['x', 'y', 'z', 'r', 'g', 'b']):
                  pointCloud_tmp[k] = pointCloud[:, :, i].reshape((height*width, 1))
              pointCloud_tmp.tofile(f)
          else:
              # dt = np.dtype([('x', np.float32),
              #                ('y', np.float32),
              #                ('z', np.float32),
              #                #('I', np.uint8)]
              # )
              # pointCloud_tmp = np.zeros((height*width), dtype=dt)
              # for i, k in enumerate(['x', 'y', 'z']):
              #     pointCloud_tmp[k] = pointCloud[:, :, i].reshape((height*width, 1))
              # pointCloud_tmp.tofile(f)
              f.write(pointCloud.astype(np.float32).data.tobytes())
              
def readPCD(filename):
    with open(filename, 'rb') as f:
        #"# .PCD v.7 - Point Cloud Data file format\n"
        f.readline()

        #"VERSION .7\n"
        f.readline()

        # "FIELDS x y z\n"
        fields = f.readline().strip().split()[1:]

        if len(fields) == 3:
            rgb = False
        elif len(fields) == 4:
            rgb = True
        else:
            raise Exception("Unsupported fields: %s" % str(fields))

        #"SIZE 4 4 4\n"
        sizes = [int(x) for x in f.readline().strip().split()[1:]]
        pointSize = np.sum(sizes)

        #"TYPE F F F\n"
        types = f.readline().strip().split()[1:]

        #"COUNT 1 1 1\n"
        counts = [int(x) for x in f.readline().strip().split()[1:]]

        #"WIDTH %d\n" % width
        width = int(f.readline().strip().split()[1])

        #"HEIGHT %d\n" % height
        height = int(f.readline().strip().split()[1])

        #"VIEWPOINT 0 0 0 1 0 0 0\n"
        viewpoint = np.array(f.readline().strip().split()[1:])

        #"POINTS %d\n" % height * width
        points = int(f.readline().strip().split()[1])

        #"DATA ascii\n"
        format = f.readline().strip().split()[1]
        ascii = format == 'ascii'

        if rgb:
            pointCloud = np.empty((height, width, 6))
        else:
            pointCloud = np.empty((height, width, 3))

        for row in range(height):
            for col in range(width):
                if ascii:
                    data = [float(x) for x in f.readline().strip().split()]
                else:
                    data = unpack('fff', f.read(pointSize))

                pointCloud[row, col, 0] = data[0]
                pointCloud[row, col, 1] = data[1]
                pointCloud[row, col, 2] = data[2]
                if rgb:
                    rgb_float = unpack('f', f.read(1))
                    packed = pack('f', rgb_float)
                    rgb_int = unpack('i', packed)[0]
                    r = rgb_int >> 16 & 0x0000ff
                    g = rgb_int >> 8 & 0x0000ff
                    b = rgb_int & 0x0000ff
                    pointCloud[row, col, 3] = r
                    pointCloud[row, col, 4] = g
                    pointCloud[row, col, 5] = b

        return pointCloud
