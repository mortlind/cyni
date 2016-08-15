import cyni
import numpy as np
from PIL import Image

cyni.initialize()
device = cyni.getAnyDevice()
device.open()
depthStream = device.createStream(b"depth", fps=30)
#colorStream = device.createStream(b"color", fps=30)
depthStream.start()
#colorStream.start()
#colorFrame = colorStream.readFrame()
depthFrame = depthStream.readFrame()
cloud = cyni.depthMapToPointCloud(depthFrame.data, depthStream)
#cloud = cyni.depthMapToPointCloud(depthFrame.data, depthStream, colorFrame.data)
cyni.writePCD(cloud, "cloud_ascii.pcd", ascii=True)
cyni.writePCD(cloud, "cloud_bin.pcd")
read_bin_cloud = cyni.readPCD("cloud_bin.pcd")
