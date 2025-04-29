#!/usr/bin/env python3

# copyright 2024-2025 by gh-hastmu@gmx.de
# homed at: https://github.com/hastmu/avahi-backup

import signal
import sys
import base64
import threading
import multiprocessing
import os
import hashlib
import atexit
import time
import pickle
import math
import argparse

import timeit

import zlib
#import gzip
#import lzma

# defaults
from pathlib import Path

_CFG={
   "default_hash_basedir": str(Path.home())+"/.cache/avahi-backup/hashes"
}


parser = argparse.ArgumentParser("filehasher")
parser.add_argument("--version", action='store_true', help="show version and exit")
parser.add_argument("--debug", action='store_true', help="enable debug messages")
parser.add_argument("--report-used-hashfile", action='store_true', help="reports used hashfile and exits.")
parser.add_argument("--thread-mode", help="0=no-threading, 1=read+hash threading, 2=hash threading", type=int, default=0)

group = parser.add_argument_group('Hashing...')
group.add_argument("--inputfile", help="file which should be hashed.", type=str, default=False)
group.add_argument("--min-chunk-size", help="smallest chunk for hashing.", type=int, default=8192)
group.add_argument("--build-only", help="build only - no compare", type=bool, default=True)
group.add_argument("--force-refresh", action='store_true', help="refresh also available hashes in build-only mode")
group.add_argument("--hashfile", help="define which hashfile is used",default=False)

group = parser.add_argument_group('Verifying...')
group.add_argument("--verify-against", help="hashed which should be verified for matching", type=str, default=False)
group.add_argument("--delta-file", help="store deltas to this file for patching", type=str, default=False)
group.add_argument("--remote-delta", action='store_true', help="sent delta for remote-patching")
group.add_argument("--chunk-limit", help="limit written deltas per run", type=int, default=False)
group = parser.add_argument_group('Patching...')
group.add_argument("--apply-delta-file", help="patches the inputfile with the content of the delta file", type=str, default=False)

group = parser.add_argument_group('Remote patching...')
group.add_argument("--remote-patching", action='store_true', help="starts remote patching process via ssh...")
group.add_argument("--remote-hostname", help="remote hostname", type=str, default=False)
group.add_argument("--remote-src-filename", help="remote file name which is source of patching", type=str, default=False)
group.add_argument("--remote-username", help="ssh key to load in addition to use", type=str, default=False)
group.add_argument("--remote-password", help="ssh key to load in addition to use", type=str, default=False)
group.add_argument("--remote-ssh-key", help="ssh key to load in addition to use", type=str, default=False)
group.add_argument("--remote-transfer-mode", help="0 (default): json-ascii, 1: binary, 2: bin+compression, 3: bin+auto-compress", type=int, default=0)

group = parser.add_argument_group('Debugging...')
group.add_argument("--show-hashes", help="lists stored hashes in hash file", type=str, default=False)

args = parser.parse_args()

# exit function
def save_hash_file():
   # print("---save hash---")
   FH.save_hash()


def sigterm_handler(_signal, _stack_frame):
   # Raises SystemExit(0):
##   os.write(sys.stdout.fileno(), b"-- signal handler --\n")
#   print("-- signal handler --")
 #  print(f"{_signal}")
#   signal.signal(signal.SIGTERM, False)
#   signal.signal(signal.SIGINT, False)
   try:
      FH.save_hash()
   except:
      pass

   #sys.exit(2)
   os._exit(2)


class speed():

   def __init__(self,*, max_size=False, start_chunk=0):
      self.min=False
      self.max=False
      self.avg=False
      self.max_size=max_size
      self.chk_read_count_max=1
      self.chk_read_count=1
      self.abs_chk_reads=start_chunk
      self.s_time=time.time()

   def update_run(self,size):
      
      # update total counter
      self.abs_chk_reads=self.abs_chk_reads+1

      # update cycle counter
      self.chk_read_count=self.chk_read_count-1
      self.e_time=time.time()
      age=(self.e_time - self.s_time)
      if age > 2:
         # too long - adapt to current possible values.
         self.chk_read_count_max=self.chk_read_count_max-self.chk_read_count
         self.chk_read_count=0

      if self.chk_read_count == 0:
         if age < 1:
            # too fast increase sampling time
            self.chk_read_count_max=self.chk_read_count_max*2
         else:
            # only consider reasonable ages
            self.update(self.chk_read_count_max * size / age)
         self.chk_read_count=self.chk_read_count_max
         # output stats
#         print(f"chunk {self.chk} of {(self.chk*100/self.max_chk):3.2f}% size={self.chunk_size} read in {read_speed.report()}", end="\r")
         if self.max_size is False:
            print(f"chunk processed {self.abs_chk_reads:12} at {self.report()}", end="\r")
         else:
            print(f"chunk processed {self.abs_chk_reads:12} of {(self.abs_chk_reads*100/(self.max_size/size)):>6.2f}% at {self.report()} with Threads[{threading.active_count()}|{len(multiprocessing.active_children())}]", end="\r")

         # new cycle
         self.s_time=time.time()

   def update(self,value):
      if self.min is False:
         self.min=value
      elif self.min > value:
         self.min=value

      if self.max is False:
         self.max=value
      elif value > self.max:
         self.max=value

      if self.avg is False:
         self.avg=value
      else:
         self.avg=(self.avg + value) / 2

   def size_bw(self,value):
      idx=0
      units=("B/s","KB/s","MB/s","GB/s","TB/s","PB/s")
      while value > 1024:
         idx=idx+1
         value=value/1024

      return str(int(value)) + " " + units[idx]

   def report(self):
#      result=self.size_bw(self.min)+" - " + self.size_bw(self.avg) + " - " + self.size_bw(self.max)
      result=f"{self.size_bw(self.min):4} - {self.size_bw(self.avg):4} - {self.size_bw(self.max):4}"
      return result
   
class benchmark():

   def __init__(self,name):
      self.start=timeit.default_timer()
      self.name=name

   def __enter__(self):
      pass
      
   def __exit__(self,a,b,c):
      self.end=timeit.default_timer()
      print(f"{self.name} took {self.end - self.start} seconds")
      
class FileHasher():

   chunk_file_version = "v1.0.3"
   patch_file_version = "v1.0.0"
   patch_file_version_int = 1

   def __init__(self,* , inputfile=False, hashfile=False, chunk_size=8192, hash_method="flat", debug=False):

      # defaults
      self.threads=[]
      self.lock_reading=threading.Lock()
      self.lock_update_idx=threading.Lock()
      self.lock_delta_file=threading.Lock()
      self.lock_delta_stream=threading.Lock()
      self.hash_obj={}
      self.mtime=0
      self.save_hashes=False
      self._debug=debug
      self.local_delta_file_handle=False
      self.verify_reference=False
      self.remote_delta_header_sent=False
      self.remote_delta_mode=False

      # get inputfile, stats and check if exists.
      if inputfile is not False:
         if os.path.isfile(inputfile):
            self.debug(type="INFO:init",msg="inputfile="+inputfile)
            self.inputfile=inputfile
            self.inputfile_abspath=os.path.abspath(self.inputfile)
            self._refresh_inputfile_stats()
         else:
            raise Exception("Input file not found.") 
      else:
         raise Exception("Input file given.") 

      self.chunk_size=chunk_size
      self.max_chk=math.ceil(self.inputfile_stats.st_size/self.chunk_size)
      self.debug(type="INFO:init",msg="chunk_size["+str(self.chunk_size)+"] max_chk["+str(self.max_chk)+"]")

      if hashfile is False:
         # new
         self.hashfile_hashedname=hashlib.sha512(self.inputfile_abspath.encode()).hexdigest()
         os.makedirs(_CFG["default_hash_basedir"]+"/"+self.hashfile_hashedname[0:2]+"/"+self.hashfile_hashedname[2:4], exist_ok=True)
         self.hashfile=_CFG["default_hash_basedir"]+"/"+self.hashfile_hashedname[0:2]+"/"+self.hashfile_hashedname[2:4]+"/"+self.hashfile_hashedname
      else:
         self.hashfile=hashfile

      # self.load_hashes = initial | not-loaded(outdated) | not-loaded(wrong chunk-size) | loaded based on state

      data=self.load_hash(hashfile=self.hashfile, extended_tests=True)

      if data is False:
         # no useful hashes available.
         self.save_hashes=True
         self.loaded_hashes=self.loaded_hash_error
         self.hash_obj={}
      else:
         # useful hashes
         self.loaded_hashes="loaded"
         self.hash_obj=data["hashes"]
      
      self.debug(type="INFO:init",msg="Done.")

   def _refresh_inputfile_stats(self):
      self.inputfile_stats = os.stat(self.inputfile)
      self.mtime=self.inputfile_stats.st_mtime
      # print(self.inputfile_stats)

   def _read_one_chunk(self,file_object,*, chunk_size=8192,seek_chunk=-1,lock=True):

      try:
         if lock is True:
            self.lock_reading.acquire()
         if seek_chunk != -1:
            file_object.seek(seek_chunk*chunk_size)
         data = file_object.read(chunk_size)
         if lock is True:
            self.lock_reading.release()
         return bytes(data)
      except:
         if lock is True:
            self.lock_reading.release()
         return False

   def update_hash_idx(self, *, chunk, new_hash,data=None,local_delta_file=False,remote_delta=False):

      old_hash=self.hash_obj.get(chunk,False)
      if old_hash is False or old_hash != new_hash:
         # only add and flag as updated if there is a real change.
         self.debug(type="INFO:update_hash_idx",msg=f"- update {chunk} [{self.chunk_size*chunk}-{self.chunk_size*(chunk+1)}/{self.inputfile_stats.st_size}] with new[{new_hash}] old[{old_hash}]- length {self.hash_obj.__len__()}")
         self.lock_update_idx.acquire()
         self.hash_obj[chunk]=new_hash
         self.lock_update_idx.release()
         self.save_hashes=True
      else:
         self.debug(type="INFO:update_hash_idx",msg=f"- same   {chunk} with [{new_hash}]")

      # verify if so
      if self.verify_reference is not False:
         reference_hash=self.verify_reference.get(chunk,False)
         if reference_hash is False or reference_hash != new_hash:
            # mismatch
            self.debug(type="INFO:update_hash_idx",msg=f"  - verify input hash[{new_hash}] reference hash[{reference_hash}] - mismatch")
            self.mismatched_idx_hashes[chunk]=new_hash
            if local_delta_file is not False or remote_delta is not False:
               # get data if needed
               if data is None:
                  data=self._read_one_chunk(self.inputfile_handle,chunk_size=self.chunk_size,seek_chunk=chunk,lock=True)

            if local_delta_file is not False:
               with self.lock_delta_file:
                  # TODO: if data=none read
                  # establish file handle for delta file if not done already.
                  if self.local_delta_file_handle is False:
                     self.debug(type="INFO:update_hash_idx",msg=f"    - write to delta file: {local_delta_file}")
                     self.local_delta_file_handle=open(local_delta_file,"wb")
                     # write header
                     # current version works with stable chunks sizes, future adaptive chunks would reduce transfer size.
                     # write header
                     a=0
                     self.local_delta_file_handle.write(a.to_bytes(8,'big'))                             # number of chunks in file
                     self.local_delta_file_handle.write(self.patch_file_version_int.to_bytes(8,'big'))   # chunk file version
                     self.local_delta_file_handle.write(self.chunk_size.to_bytes(8,'big'))               # chunk_size
                     self.local_delta_file_handle.write(len(bytes.fromhex(new_hash)).to_bytes(8,'big'))  # length of hash
                     stats=pickle.dumps(self.inputfile_stats, protocol=pickle.HIGHEST_PROTOCOL)
                     self.local_delta_file_handle.write(len(stats).to_bytes(8,'big'))                    # length of hash
                     self.local_delta_file_handle.write(stats)                                           # stats.
                                          
                  # write to delta to handle
               
               self.send_patch_frame(handle=self.local_delta_file_handle,chunk=chunk,data_of_chunk=data,hash_of_chunk=new_hash,lock=self.lock_delta_file)

            if remote_delta is not False:

               with self.lock_delta_stream:
                  # always locked to be sequential - for the first header.
                  if self.remote_delta_header_sent is False:
                     self.debug(type="INFO:update_hash_idx",msg=f"    - remote_delta: send header")
                     print("header")
                     # send header

                     a=0
                     
                     self.send2stdout(a.to_bytes(8,'big'))                             # number of chunks in file
                     self.send2stdout(self.patch_file_version_int.to_bytes(8,'big'))   # chunk file version
                     self.send2stdout(self.chunk_size.to_bytes(8,'big'))               # chunk_size
                     self.send2stdout(len(bytes.fromhex(new_hash)).to_bytes(8,'big'))  # length of hash
                     stats=pickle.dumps(self.inputfile_stats, protocol=pickle.HIGHEST_PROTOCOL)
                     self.send2stdout(len(stats).to_bytes(8,'big'))                    # length of hash
                     self.send2stdout(stats)                                           # stats.

                     self.remote_delta_header_sent=True

               while self.remote_delta_header_sent is not True:
                  time.sleep(1)

               self.debug(type="INFO:update_hash_idx",msg=f"    - remote_delta: send frame")
               print("frame")
               #self.send_patch_frame(handle=sys.stdout.fileno(),chunk=chunk,data_of_chunk=data,hash_of_chunk=new_hash,lock=self.lock_delta_stream)

         else:
            #self.debug(type="INFO:update_hash_idx",msg=f"  - verify input hash[{new_hash}] reference hash[{reference_hash}] - match")
            pass

   def send2stdout(self,data):
      os.write(sys.stdout.fileno(), data)
      #sys.stdout.buffer.write(data)
      

   def hash_thread(self, *, cpu=-1,Read_file=False, local_delta_file=False,remote_delta=False):

      self.debug(type="INFO:hash_thread",msg=f"- hashing thread cpu[{cpu}] - start")

      with open(self.inputfile,"rb") as f:
         while self.active is True or len(self.chunk_buffer[cpu]) > 0:
            # process buffer
            for chunk in list(self.chunk_buffer[cpu]):
               #print(f"- processing cpu[{cpu}] chunk[{chunk}]")
               if Read_file is True:
                  self.debug(type="INFO:hash_thread",msg=f"- reading cpu[{cpu}] chunk[{chunk}] length[{len(self.chunk_buffer[cpu])}]")
                  s_time=time.time_ns()
                  piece=self._read_one_chunk(f,chunk_size=self.chunk_size,seek_chunk=chunk,lock=False)
                  self.time_avg_ns_read[cpu]=((time.time_ns()-s_time) + self.time_avg_ns_read[cpu]) / 2

               else:
                  self.debug(type="INFO:hash_thread",msg=f"- processing cpu[{cpu}] chunk[{chunk}] length[{len(self.chunk_buffer[cpu])}]")
                  piece=self.chunk_buffer[cpu].get(chunk,False)

               if piece is not False:
                  del self.chunk_buffer[cpu][chunk]
                  data=hashlib.sha256(piece)
                  self.update_hash_idx(chunk=chunk,new_hash=data.hexdigest(),data=piece,local_delta_file=local_delta_file,remote_delta=remote_delta)

            time.sleep(0.001)

      self.debug(type="INFO:hash_thread",msg=f"- hashing thread cpu[{cpu}] - end")

   def hash_file(self, *, incremental=True,threading_mode=0,verify_hash_file=False,local_delta_file=False,remote_delta=False):
      # update stats
      self._refresh_inputfile_stats()
      # defaults for def handshake
      self.data={}
      self.delta_file=False
      self.delta_remote=False
      # defaults for verification
      self.mismatched_idx=[]
      self.mismatched_idx_hashes={}
      # for delta
      self.remote_delta_header_sent=False
      if remote_delta is False:
         self.remote_delta_mode=False
      else:
         self.remote_delta_mode=True

      # TODO: Revisit incremental with the new index missing scheme.
      if incremental is False:
         self.hash_obj={}
      # load hash to verify against if given
      if verify_hash_file is not False:
         self.debug(type="INFO:hash_file",msg=f"- verify reference: {verify_hash_file}")
         loaded=self.load_hash(hashfile=verify_hash_file,extended_tests=False)
         if loaded is not False:
            self.verify_reference=loaded["hashes"]
         else:
            raise Exception("unable to load verification hashes")
         incremental=False
      else:
         self.verify_reference=False

      # hash

      self.chk=int(0)
      with open(self.inputfile,"rb") as f:
         # make this a obj attribute
         self.inputfile_handle=f

         if incremental is True:
            self.chk=len(self.hash_obj)-1
            if self.chk < 0:
               self.chk=0
            self.debug(type="INFO:hash_file",msg=f"- Incremental starting with chunk {self.chk}")
            self.loaded_hashes=self.loaded_hashes+" - inc["+str(self.chk)+"-"+str(self.max_chk-1)+"]"
            f.seek(self.chk*self.chunk_size)
         else:
            self.debug(type="INFO:hash_file",msg="- Full...")
            f.seek(0)

         read_speed=speed(max_size=self.inputfile_stats.st_size,start_chunk=self.chk)

         self.debug(type="INFO:hash_file",msg="- Threading mode: "+str(threading_mode))

         if threading_mode == 0:
            # non-threading mode

            for chunk in range(0,self.max_chk):
               old_data=self.hash_obj.get(chunk,False)
               if old_data is False:
                  # missing hash
                  self.debug(type="INFO:hash_file",msg=f"- missing chunk[{chunk}]")
                  try:
                     data_chunk=self._read_one_chunk(f,chunk_size=self.chunk_size,seek_chunk=chunk)
                     data_hash=hashlib.sha256(data_chunk)
                     self.update_hash_idx(chunk=chunk,new_hash=data_hash.hexdigest(),data=data_chunk,local_delta_file=local_delta_file,remote_delta=remote_delta)
                     if self.remote_delta_mode is False:
                        read_speed.update_run(self.chunk_size)
                  except:
                     self.debug(type="INFO:hash_file",msg="  - failed -> exception")
                     pass
               elif verify_hash_file is not False:
                  self.update_hash_idx(chunk=chunk,new_hash=old_data,local_delta_file=local_delta_file,remote_delta=remote_delta)
               else:
                  #self.debug(type="INFO:hash_file",msg=f"- already chunk[{chunk}] = {self.hash_obj[chunk]}")
                  pass

         elif threading_mode == 1 or threading_mode == 2:
            # 1 = read+hash, 2 = hash

            # BROKEN-doest not build all chunks.

            self.chunk_buffer={}
            self.thread={}
            self.active=True

            max_cpu_count=multiprocessing.cpu_count()
            cpu_count=max_cpu_count

            self.time_avg_ns_read={}
            self.time_avg_ns_hash={}
            for cpu in range(0,cpu_count):
               self.chunk_buffer[cpu]={}
               self.time_avg_ns_read[cpu]=0
               self.time_avg_ns_hash[cpu]=0
               if threading_mode == 1:
                  self.thread[cpu]=threading.Thread(target=self.hash_thread,kwargs={"cpu":cpu, "Read_file":True, "local_delta_file": local_delta_file, "remote_delta": remote_delta })
               else:
                  self.thread[cpu]=threading.Thread(target=self.hash_thread,kwargs={"cpu":cpu, "Read_file":False, "local_delta_file": local_delta_file, "remote_delta": remote_delta })
               self.thread[cpu].start()

            next_cpu=0
            target_bw_s=10*1024*1024*1024 #  10GiB/s
            chunks_per_s=target_bw_s / self.chunk_size
            time_per_chunk=1/chunks_per_s
            self.debug(type="INFO:hash_file",msg=f"- time per chunk at target bw: {time_per_chunk} sec")
            # purely artificially chosen limits, a little bit tuned while development.
            max_queue_length=32
            min_queue_length=8
            # default sensor values
            immune_count=0
            sensor=cpu_count
            self.chunk_buffer[sensor]=[]
            # chunk cycling.
            for chunk in range(0,self.max_chk):

               old_data=self.hash_obj.get(chunk,False)
               if old_data is False:

                  self.debug(type="INFO:hash_file",msg=f"- missing chunk[{chunk}]")

                  # wait a glimpse of time to not overload unneeded the system.
                  time.sleep(time_per_chunk/cpu_count) # keep back to not overload queues

                  # missing hash - guidance or data for threads
                  if threading_mode == 1:
                     self.chunk_buffer[next_cpu][chunk]=True
                     # if queue length is over the limit then reduce the active filled threads
                  else:
                     s_time=time.time_ns()
                     self.chunk_buffer[next_cpu][chunk]=self._read_one_chunk(f,chunk_size=self.chunk_size,seek_chunk=chunk)
                     self.time_avg_ns_read[next_cpu]=((time.time_ns()-s_time) + self.time_avg_ns_read[next_cpu]) / 2

                  # eval on performance and tune
                  # idea:
                  # - if queue length is max then the system (io or/and cpu) is too slow.
                  #   - therefore reduce pressure by increasing time_per_chunk 
                  # - if read times are too spread the io system is overloaded
                  #   - reduce threads.

                  
                  # - get max queue length
                  current_min_queue_length=False
                  current_max_queue_length=0
                  current_avg_read=False
                  current_min_avg_read=False
                  current_max_avg_read=0
                  # understand if the avg time to read of a cpu is higher than the avg_read time
                  for cpu in range(0,cpu_count):
                     # get avg read
                     avg_read=self.time_avg_ns_read[cpu]
                     if current_avg_read is False:
                        current_avg_read=avg_read
                     else:
                        current_avg_read=(avg_read + current_avg_read ) /2
                     # get min and max
                     if avg_read > current_max_avg_read:
                        current_max_avg_read=avg_read
                     if avg_read < current_min_avg_read or current_min_avg_read is False:
                        current_min_avg_read=avg_read
                     # get queue length
                     queue_length=len(self.chunk_buffer[cpu])
                     if queue_length > current_max_queue_length:
                        current_max_queue_length=queue_length
                     if queue_length < min_queue_length or current_min_queue_length is False:
                        # the cpu with the smallest queue wins the next task
                        current_min_queue_length=queue_length
                        next_cpu=cpu
                  if current_min_avg_read == 0:
                     current_min_avg_read=0
                     avg_read_spread=1
                  else:
                     avg_read_spread=current_max_avg_read/current_min_avg_read
                  #debug#print(f"- cpu[{cpu_count:>2}] queue_length: {current_min_queue_length:>2}-{current_max_queue_length:>2} -- read [{current_min_avg_read:>12.2f}/{current_max_avg_read:>12.2f}:{avg_read_spread:>3.1f}] -- {time_per_chunk:>12f} sec - read[{current_avg_read:>12.2f}]\r",end="")

                  # if time_per_chunk is too small the chunk size is too small or the machine too fast.
                  if time_per_chunk < current_avg_read/1e9 and current_min_queue_length > min_queue_length:
                     #debug#print("- limit chunk time to avg read")
                     time_per_chunk=current_avg_read/1e9

                  # - correction of chunk time - we fill the cpu queue faster than processing.
                  if current_max_queue_length >= max_queue_length:
                     # not larger than 250 ms
                     time.sleep(time_per_chunk) # do extra wait.
                     # correct
                     if time_per_chunk < 0.250:
                        time_per_chunk=time_per_chunk*1.1
                        ##print(f"- new time per chunk: {time_per_chunk} sec (increasing)")
                     else:
                        time_per_chunk=0.250

                  elif current_min_queue_length < min_queue_length and immune_count == 0:
                     # queue becomes smaller than the min limit, we can put more load in the queue.
                     time_per_chunk=time_per_chunk*0.9
                     ##print(f"- new time per chunk: {time_per_chunk} sec (decreasing)")
#                     if cpu_count < max_cpu_count:
#                        max_queue_length=max_queue_length*1.1
#                        #min_queue_length=max_queue_length
#                        print("- adding active queues...")
#                        cpu_count=cpu_count+1
#                        immune_count=int(2*max_queue_length)

                  elif avg_read_spread > 2 and len(self.chunk_buffer[sensor]) == 0:
                     # if time becomes to high, the io-system is to slow, therefore reduce threads                     
                     sensor=cpu_count-1
                     if cpu_count > 1:
                        if avg_read_spread > 20:
                           # drop dramatic if spread is too high
                           cpu_count=int(cpu_count/2)
                        else:
                           # proceed slowly to lower threads.
                           cpu_count=cpu_count-1
                        # mark active +1 one as sensor cpu for the queue overload 
                        # so self.chunk_buffer[sensor] is 0,(cpu_count-1), therefore cpu_count is the first in the old segment.
                        sensor=cpu_count

#                     print(f"- cut down threads: {cpu_count}")
                  elif avg_read_spread < 1.5:
                     # ok so add more active threads, if not already all involved
                     if cpu_count < max_cpu_count:
                        cpu_count=cpu_count+1
                        sensor=cpu_count

                  #print(f"- sensor: {cpu_count}/{sensor} {len(self.chunk_buffer[sensor])}")

                  if immune_count > 0:
                     # decrease the immune count, out-dated, as sensor is used now
                     immune_count=immune_count-1

                  if self.remote_delta_mode is False:
                     read_speed.update_run(self.chunk_size)

               elif verify_hash_file is not False:
                  self.update_hash_idx(chunk=chunk,new_hash=old_data,local_delta_file=local_delta_file)

               else:
                  #self.debug(type="INFO:hash_file",msg=f"- already chunk[{chunk}] = {self.hash_obj[chunk]}")
                  pass

            self.active=False

            for cpu in range(0,multiprocessing.cpu_count()):
               self.thread[cpu].join()
            
         else:
            raise Exception("threading mode unknown")
            
      if self.remote_delta_mode is False:
         print(f"\33[2K\r",end='\r')
         print(len(self.mismatched_idx_hashes.keys()))

   def send_patch_frame(self, *, handle=False,chunk=-1,hash_of_chunk=False,data_of_chunk=False,lock=False):

      if handle is not False and hash_of_chunk is not False and data_of_chunk is not False and chunk != -1 and lock is not False:
         self.debug(type="INFO:send_patch_frame",msg=f"...send patch frame for chunk[{chunk}] data[{len(data_of_chunk)}]")

         data_compressed=zlib.compress(data_of_chunk)
         if len(data_compressed) < len(data_of_chunk):
            self.debug(type="INFO:send_patch_frame",msg=f"   - compressed [zlib]")
            compressed=1
            data_to_write=data_compressed
         else:
            self.debug(type="INFO:send_patch_frame",msg=f"   - uncompressed")
            compressed=0
            data_to_write=data_of_chunk
         
         data_length=len(data_to_write)
         self.debug(type="INFO:send_patch_frame",msg=f"   - frame length {data_length}")

         # DONE: conclude how to store
         # https://stackoverflow.com/questions/7856196/how-to-translate-from-a-hexdigest-to-a-digest-and-vice-versa
         # h.digest().hex()
         # bytes.fromhex(h.hexdigest())
#         with lock:
#            handle.write(chunk.to_bytes(8,'big'))              # chunk number
#            handle.write(bytes.fromhex(hash_of_chunk))         # hash
#            handle.write(compressed.to_bytes(1,'big'))         # compressed ? 0=no, 1=zlib
#            handle.write(data_length.to_bytes(8,'big'))        # data_frame length
#            handle.write(data_to_write)                        # data

         data_raw=chunk.to_bytes(8,'big')+bytes.fromhex(hash_of_chunk)+compressed.to_bytes(1,'big')+data_length.to_bytes(8,'big')+data_to_write
         # TODO: conclude if lock is needed, write is most likely thread safe.
         #with lock:

         if self.remote_delta_mode is False:
            handle.write(data_raw)
         else:
            self.send2stdout(data=data_raw)

   def send_data(self,*, handle=False, data=False):

      if self.remote_delta_mode is False:
         handle.write(data_raw)
      else:
         self.send2stdout(data=data_raw)

   def send_msg(self, *, type=False, data={}):
      data["type"]=type
      import base64
      send_data=pickle.dumps(data, protocol=pickle.HIGHEST_PROTOCOL)
      send_data=base64.b64encode(send_data).decode()
      print(f"{len(send_data)}")
      print(send_data,end="")

   def receive_msg(self,*, pipe):
      data={}
      try:
         length=pipe.readline().strip()
         if length.isdigit():
            data=pipe.read(int(length))
            data=pickle.loads(base64.b64decode(data))
         else:
            data["type"]="null"
      except:
         data["type"]="null"
      return data

   def verify_against(self,*, hash_filename, write_delta_file=False, chunk_limit=False, remote_delta=False):

      self.debug(type="INFO:verify_against",msg="Start - hash_filename["+str(hash_filename)+"] write_delta_file["+str(write_delta_file)+"] chunk_limit["+str(chunk_limit)+"]")
      # prepare delta metadata
      if write_delta_file is not False:
         patch_data={
            "version": self.patch_file_version,
            "stats" : self.inputfile_stats,
            "chunk_size": self.chunk_size,
            "mismatch_idx": [], 
            "mismatch_idx_hashes": {} 
         }
      # remote delta
      if remote_delta is not False:
         patch_data={
            "version": self.patch_file_version,
            "stats" : self.inputfile_stats,
            "chunk_size": self.chunk_size,
         }
         self.send_msg(type="metadata",data=patch_data)

      # load hashfile to verify against.
      verify=self.load_hash(hashfile=hash_filename,extended_tests=False)

      read_speed=False
      source_file=False
      inputfile_handle=False

      if verify is not False:
         loaded_hashes=len(verify["hashes"])
         # init counts
         count=match=mismatch=0
         self.mismatched_idx=[]
         self.mismatched_idx_hashes={}

         if write_delta_file is not False:
            delta_file=open(write_delta_file, 'wb')
            print(f"- write delta files {write_delta_file}...")

         # cycle through all chunks
         for self.chk in range(0,self.max_chk):

            if chunk_limit != False and mismatch >= chunk_limit:
               # break if we reached chunk_limit
               break
            else:
               # get hashes and compare
               input_hash=self.hash_obj.get(self.chk,False)
               compare_hash=verify["hashes"].get(self.chk,False)
               data_chunk=False

               # refresh chk if needed
               if input_hash is False:
                  if read_speed is False:
                     read_speed=speed(max_size=self.inputfile_stats.st_size,start_chunk=self.chk)
                  if source_file is False:
                     source_file=open(self.inputfile,"rb")
                     source_file.seek(0)
                  # we need to hash the file again.
                  # TODO: make that method agnostic.
                  if remote_delta is False:
                     read_speed.update_run(self.chunk_size)
                  source_file.seek(self.chk*self.chunk_size)
                  data_chunk=source_file.read(self.chunk_size)
                  # calc hash
                  data_hash=hashlib.sha256(data_chunk)
                  # convert to string
                  self.hash_obj[self.chk]=data_hash.hexdigest()
                  #
                  input_hash=self.hash_obj[self.chk]
                  self.save_hashes=True
                  self.debug(type="INFO:verify_against",msg="read inputfile chk["+str(self.chk)+"] hash["+str(input_hash)+"]")
   #               print(f"new hash {self.hash_obj[self.chk]} for chk {self.chk}")

               # compare
               if input_hash == compare_hash and input_hash is not False:
                  match=match+1
               else:
                  mismatch=mismatch+1
                  self.debug(type="INFO:verify_against",msg="delta at chk["+str(self.chk)+"] SRC["+str(input_hash)+"] VERIFY["+str(compare_hash)+"]")
                  
                  if write_delta_file is not False or remote_delta is not False:
                     if source_file is False:
                        source_file=open(self.inputfile,"rb")
                        source_file.seek(0)
                     self.mismatched_idx.append(self.chk)
                     self.mismatched_idx_hashes[self.chk]=input_hash
                     # seek source file
                     if data_chunk is False:
                        self.debug(type="INFO:verify_against",msg="re-read inputfile chk["+str(self.chk)+"] hash["+str(input_hash)+"]")
                        source_file.seek(self.chk*self.chunk_size)
                        data_chunk=source_file.read(self.chunk_size)
                     
                     if write_delta_file is not False:
                        delta_file.write(data_chunk)
                     if remote_delta is not False:
                        send_data={
                           "chunk": self.chk,
                           "chunk_data": data_chunk,
                           "chunk_hash": input_hash
                        }
                        self.send_msg(type="chunk",data=send_data)

                     self.debug(type="INFO:verify_against",msg="write delta file chk["+str(self.chk)+"] data-length["+str(len(data_chunk))+"]")

         #print(f"\33[2K\r",end='\r')
         print(f"verify [#{loaded_hashes}:{hash_filename}] loaded - M[#{match}:!#{mismatch}]")

         if write_delta_file is not False:
            if source_file is not False:
               source_file.close()
            delta_file.close()
            if mismatch > 0:
               patch_data["mismatch_idx"]=self.mismatched_idx
               patch_data["mismatch_idx_hashes"]=self.mismatched_idx_hashes
               with open(write_delta_file+".hash", 'wb') as handle:
                  pickle.dump(patch_data, handle, protocol=pickle.HIGHEST_PROTOCOL)
            else:
               os.remove(write_delta_file)
      else:
         raise Exception("can not read hash file")

      self.debug(type="INFO:verify_against",msg="Done")

   def patch_chk(self, *, target_file=False, chunk=False, chunk_data=False, chunk_hash=False):

      close_file=False
      if target_file is False:
         target_file=open(self.inputfile, 'r+b')
         close_file=True

      target_file.seek(chunk * self.chunk_size)
      data_hash=hashlib.sha256(chunk_data)
      data_hash=data_hash.hexdigest()
      if data_hash == chunk_hash:
         self.save_hashes=True
         self.hash_obj[chunk]=data_hash
         target_file.write(chunk_data)
      else:
         raise Exception(f"patch_chk: received data and target hash do not match! Fatal.")
      
      if close_file == True:
         target_file.close()

   def apply_stats(self, *, stats=False):

      if stats is not False:
         with open(self.inputfile,"r+b") as target_file:
            target_file.truncate(stats.st_size)

         # apply/update metadata
         os.chown(self.inputfile,stats.st_uid,stats.st_gid)
         os.utime(self.inputfile,ns=(stats.st_atime_ns,stats.st_mtime_ns))

   def read_patch_stream(self,handle,size):

      if self.remote_delta_mode is False:
         # file
         self.debug(type="INFO:read_patch_stream",msg=f"file mode {size}")
         data=handle.read(size)         
      else:
         # ssh stdout
         self.debug(type="INFO:read_patch_stream",msg=f"stream mode {size}")
         data=handle.channel.recv(size)
      self.debug(type="INFO:read_patch_stream",msg=f"data: {data}")
      return data

   def patch(self, *, delta_file=False,delta_stream_handle=False):

      if delta_file is False and delta_stream_handle is False:
         raise Exception("no delta file nor stream provided")
      elif delta_file is not False and os.path.isfile(delta_file) is False and delta_stream_handle is False:
         raise Exception(f"delta file do not exist or has issues: {delta_file}")
      elif delta_file is not False and delta_stream_handle is not False:
         raise Exception("delta file and stream provided - thats not implemented.")
      elif delta_file is not False:
         # 1) open delta_file
         self.debug(type="INFO:patch",msg=f"open delta_file: {delta_file}")
         patch_data_file=open(delta_file, 'rb')
         self.remote_delta_mode=False
      elif delta_stream_handle is not False:
         # 1) open delta_file_stream
         self.debug(type="INFO:patch",msg="using delta_file_stream")
         patch_data_file=delta_stream_handle
         self.remote_delta_mode=True
      else:
         raise Exception("not idea how you got here, but thats not good.")

      # 2) read header 
      patch_file_number_of_chunks=int.from_bytes(self.read_patch_stream(patch_data_file,8),'big')
      patch_file_format_version=int.from_bytes(self.read_patch_stream(patch_data_file,8),'big')
      patch_file_chunk_size=int.from_bytes(self.read_patch_stream(patch_data_file,8),'big')
      patch_file_hash_length=int.from_bytes(self.read_patch_stream(patch_data_file,8),'big')
      patch_file_stats_length=int.from_bytes(self.read_patch_stream(patch_data_file,8),'big')
      patch_file_stats_data=self.read_patch_stream(patch_data_file,patch_file_stats_length)

      print(f"- patch/run: #ofChunks[{patch_file_number_of_chunks}] - version[{patch_file_format_version}/{self.patch_file_version_int}] - chunk size[{patch_file_chunk_size}/{self.chunk_size}] - hash length[{patch_file_hash_length}]")
      if patch_file_format_version != self.patch_file_version_int or self.chunk_size != patch_file_chunk_size:
         raise Exception("version/chunk size mismatch.")

      raise Exception("version/chunk size mismatch.")

      patch_file_stats=pickle.loads(patch_file_stats_data)

      with open(self.inputfile, 'r+b') as target_file:
         # 3) read patch frames and apply

         while True:
            try:
               frame_chunk = int.from_bytes(self.read_patch_stream(patch_data_file,8),'big')
               frame_hash_hexdigest = self.read_patch_stream(patch_data_file,patch_file_hash_length).hex()
               frame_compressed = int.from_bytes(self.read_patch_stream(patch_data_file,1),'big')
               frame_data_length = int.from_bytes(self.read_patch_stream(patch_data_file,8),'big')
               if frame_data_length > 0:
                  print(f"- chunk {frame_chunk} - C[{frame_compressed}] - L[{frame_data_length}]")
                  print(f"  - digest patch[{frame_hash_hexdigest}]")
                  frame_data_raw = self.read_patch_stream(patch_data_file,frame_data_length)

                  old_hash=self.hash_obj.get(frame_chunk,False)
                  if old_hash is False or old_hash != frame_hash_hexdigest:
                     # uncompress if needed
                     if frame_compressed == 0:
                        frame_write_data=frame_data_raw
                     elif frame_compressed == 1:
                        frame_write_data=zlib.decompress(frame_data_raw)
                     else:
                        raise Exception(f"Delta Frame with unknown compression type {frame_compressed}")
                     # hash
                     frame_write_data_hash=hashlib.sha256(frame_write_data).hexdigest()
                     print(f"  - digest write[{frame_write_data_hash}]")
                     if frame_hash_hexdigest != frame_write_data_hash:
                        raise Exception("Delta Frame hash does not match shipped data.")
                     # check if we need to write
                     target_file.seek(frame_chunk*self.chunk_size)
                     target_file.write(frame_write_data)
                     self.update_hash_idx(chunk=frame_chunk,new_hash=frame_hash_hexdigest)
                  else:
                     print(f"  - digest local[{frame_hash_hexdigest}] match")
               else:
                  break
            except:
               break

      patch_data_file.close()

      # apply/update metadata
      print(f"- truncate to "+str(patch_file_stats.st_size)+".")
      self.apply_stats(stats=patch_file_stats)

      self._refresh_inputfile_stats()
      print(f"- Done.")

   def patch_old(self, *, delta_file=False):

      if delta_file == False:
         raise Exception("no delta file provided")
      elif os.path.isfile(delta_file) == False or os.path.isfile(delta_file+".hash") == False:
         raise Exception("delta file do not exist or not complete")
      else:
         # read hash file
         # DONE: add meta data like file format version + chunk size to check if mismatches would corrupt the target file
         # - patch_data is there evaluate it and apply stats to target file.

         # loads and checks, version + chunk_size
         patch_data=self.load_hash(hashfile=delta_file+".hash",extended_tests=False,type_patch_file=True)
         
         patch_chk_list=patch_data["mismatch_idx"]
         print(f"- {len(patch_chk_list)} chunks to patch...")

         with open(delta_file, 'rb') as patch_data_file:
            with open(self.inputfile, 'r+b') as target_file:
               for idx in patch_chk_list:
                  chk_data=patch_data_file.read(self.chunk_size)
                  self.patch_chk(chunk=idx,chunk_data=chk_data,chunk_hash=patch_data["mismatch_idx_hashes"][idx])
                  print(f"  - patch chk {idx} send[{self.hash_obj[idx]}] remote["+patch_data["mismatch_idx_hashes"][idx]+"]")

         # apply/update metadata
         print(f"- truncate to "+str(patch_data["stats"].st_size)+".")
         self.apply_stats(stats=patch_data["stats"])

         print(f"- Done.")
         self._refresh_inputfile_stats()

   def feedback(self):
      # save hashes ?
      if self.remote_delta_mode is False:
         if self.save_hashes is True:
            print(f"{self.loaded_hashes} - updated - hashfile[{len(self.hash_obj)}:{self.hashfile}] - chunk-size[{self.chunk_size}]")
         else:
            print(f"{self.loaded_hashes} - unchanged - hashfile[{len(self.hash_obj)}:{self.hashfile}] - chunk-size[{self.chunk_size}]")

   def debug(self,*,type="INFO",msg="-"):
      if self._debug == True:
         #print(f"[{type}]: {msg}")
         os.write(sys.stderr.fileno(), f"[{type:>20}]: {msg}\n".encode())

   def load_hash(self,*, hashfile=False, extended_tests=False,type_patch_file=False):

      self.loaded_hash_error="-"
      if hashfile != False:
         data=False
         if hashfile == "-":
            # stdin is used
            self.debug(type="INFO:load_hash",msg="Loading hashfile from stdin")
            data=pickle.load(sys.stdin.buffer)
         elif os.path.isfile(hashfile):
            self.debug(type="INFO:load_hash",msg="Loading hashfile cwd["+os.getcwd()+"]"+hashfile)
            with open(hashfile, 'rb') as handle:
               try:
                  data = pickle.load(handle)
               except:
                  self.debug(type="INFO:load_hash",msg="unpickling of data failed.")
                  self.loaded_hash_error="not-loaded(unpickling)"
                  return False

                  
         if data != False:
            
            try:
               # check version

               if type_patch_file == False:
                  target_version=self.chunk_file_version
               else:
                  target_version=self.patch_file_version

               if data["version"] != target_version:
                  self.debug(type="INFO:load_hash",msg="version mismatch self["+str(target_version)+"] file["+str(data["version"])+"]")
                  self.loaded_hash_error="not-loaded(version)"
                  return False
               # check chunk_size
               if data["chunk_size"] != self.chunk_size:
                  self.debug(type="INFO:load_hash",msg="chunk_size mismatch self["+str(self.chunk_size)+"] file["+str(data["chunk_size"])+"]")
                  self.loaded_hash_error="not-loaded(wrong chunk-size)"
                  return False
               
               # extended checks
               if extended_tests == True:
                  # check if size matches
                  if data["size"] != self.inputfile_stats.st_size:
                     self.debug(type="INFO:load_hash",msg="size mismatch self["+str(self.size)+"] file["+str(data["size"])+"]")
                     self.loaded_hash_error="not-loaded(wrong-size)"
                     return False
                  # check mtime
                  if data["mtime"] != self.inputfile_stats.st_mtime:
                     self.debug(type="INFO:load_hash",msg="mtime mismatch self["+str(self.inputfile_stats.st_mtime)+"] file["+str(data["mtime"])+"]")
                     self.loaded_hash_error="not-loaded(wrong-mtime)"
                     return False
                  # check filename
                  if data["inputfile"] != os.path.abspath(self.inputfile):
                     self.debug(type="INFO:load_hash",msg="inputfile mismatch self["+self.inputfile+"] file["+data["inputfile"]+"]")
                     self.loaded_hash_error="not-loaded(wrong-inputfile)"
                     return False
            except:
               self.debug(type="INFO:load_hash",msg="exception triggered.")
               self.loaded_hash_error="not-loaded(unknown)"
               return False            
            
            # all good
            return data
         else:
            self.debug(type="WARNING:load_hash",msg="Hashfile to load does not exist.")
            self.loaded_hash_error="initial"
      else:
         raise Exception("not hash file to load provided.")
      
      return False

   def save_hash(self):

      self.debug(type="INFO:save_hash",msg=f"- start")
      # mark inactive
      self.active=False
      for cpu in range(0,multiprocessing.cpu_count()):
         try:
            self.debug(type="INFO:save_hash",msg=f"  - join thread {cpu}.")
            self.thread[cpu].join()
         except:
            self.debug(type="INFO:save_hash",msg=f"    - tried to join thread {cpu} failed.")
     
      if self.save_hashes == True:
         data={}
         data["inputfile"]=os.path.abspath(self.inputfile)
         data["version"]=self.chunk_file_version
         data["hashes"]=self.hash_obj
         data["chunk_size"]=self.chunk_size
         self._refresh_inputfile_stats()
         data["mtime"]=self.inputfile_stats.st_mtime
         data["size"]=self.inputfile_stats.st_size
         
         # save
         with open(self.hashfile, 'wb') as handle:
            pickle.dump(data, handle, protocol=pickle.HIGHEST_PROTOCOL)

         self.debug(type="INFO:save_hash",msg=f"  - saved under {self.hash_file}")


      self.feedback()
      self.debug(type="INFO:save_hash",msg=f"- end")


version="1.1.5"

if args.version is True:
   print(f"{version}")

elif args.show_hashes is not False:
   if os.path.isfile(args.show_hashes):
      #print(f"load hashes from: {args.show_hashes}")
      with open(args.show_hashes, 'rb') as handle:
         data = pickle.load(handle)
      import json
      print(json.dumps(data))
   else:
      raise Exception("can not load hash file")

elif args.remote_patching is True:
   print(f"- Remote patching...")
   # local file setup
   FH=FileHasher(inputfile=args.inputfile, chunk_size=args.min_chunk_size, hashfile=args.hashfile,debug=args.debug)
   atexit.register(save_hash_file)

   # remote connection
   import paramiko
   ssh = paramiko.SSHClient()
   ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
   if args.remote_password is False:
      private_key = paramiko.RSAKey.from_private_key_file(args.remote_ssh_key)
      ssh.connect(args.remote_hostname, username=args.remote_username, pkey=private_key, look_for_keys=False,compress=False)
   else:
      ssh.connect(args.remote_hostname, username=args.remote_username, password=args.remote_password,compress=False)
   
   # skip version check if already done. set FILEHASHER_SKIP_VERSION
   if os.environ.get("FILEHASHER_SKIP_VERSION",False) is False:
      ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command("filehasher.py --version")
      remote_version=ssh_stdout.readline().strip()
   else:
      remote_version=version

   if remote_version == version:
      # local and remote version match
      with open(FH.hashfile,"rb") as handle:
         FH.debug(type="INFO:ssh.exec_command",msg="filehasher.py --inputfile \""+args.remote_src_filename+"\" --min-chunk-size "+str(FH.chunk_size)+" --verify-against - --remote-delta")

         ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command("filehasher.py --inputfile \""+args.remote_src_filename+"\" --min-chunk-size "+str(FH.chunk_size)+" --verify-against - --remote-delta",get_pty=False)
#         ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command("filehasher.py --inputfile \""+args.remote_src_filename+"\" --min-chunk-size "+str(FH.chunk_size)+" --verify-against a --remote-delta", get_pty=True)
#         ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command("uname -a", get_pty=True)
         # send local hash file to remote
         ssh_stdin.write(handle.read())

         a=int.from_bytes(ssh_stdout.read(8),'big')
         print(a)

         #print(ssh_stdout.read(8))
         # patch with remote stream - sys.stdin.buffer
#         while ssh_stdout.channel.recv_ready() is not True:
#            time.sleep(0.1)
#         import binascii
         #hexString = str(binascii.hexlify(ssh_stdout.channel.recv(8)))          
#         hexString = str(binascii.hexlify(ssh_stdout.read(8)))          
#         print(hexString.split("'")[1].upper().replace('0X','') )
#         with open("debug.stream","wb") as d:
#            d.write(ssh_stdout.read())
#         print(ssh_stderr.read())
         #FH.patch(delta_stream_handle=ssh_stdout)

   else:
      raise Exception("local and remote version do not match")

elif args.inputfile is False:
   print("please use -h for help.")
   exit(0)

else:
   #print (args)
   FH=FileHasher(inputfile=args.inputfile, chunk_size=args.min_chunk_size, hashfile=args.hashfile,debug=args.debug)
   #a=1
#   print(a.to_bytes(8,'big'))
   #os.write(sys.stdout.fileno(), a.to_bytes(8,'big'))
   #a=2
   #os.write(sys.stdout.fileno(), a.to_bytes(8,'big'))
#   print(a.to_bytes(8,'big'))
   FH.send2stdout(a.to_bytes(8,'big'))

   if args.report_used_hashfile is True:
      print(f"{FH.hashfile}")
      exit(0)

   atexit.register(save_hash_file)
   signal.signal(signal.SIGTERM, sigterm_handler)
   signal.signal(signal.SIGINT, sigterm_handler)
   signal.signal(signal.SIGHUP, sigterm_handler)

   #sys.stdout.buffer.write(b"1000")
#   print(b'\x01\x00\x00\x00\x00\x00\x00\x00')

   if args.apply_delta_file is False:

      # normal hashing + local delta + remote delta
      if args.force_refresh is True:
         FH.hash_file(incremental=False,threading_mode=args.thread_mode,verify_hash_file=args.verify_against,local_delta_file=args.delta_file,remote_delta=args.remote_delta)
      else:
         FH.hash_file(incremental=True,threading_mode=args.thread_mode,verify_hash_file=args.verify_against,local_delta_file=args.delta_file,remote_delta=args.remote_delta)

      # TODO: check remote-delta response.
      # verify_against result
      if args.verify_against is not False:
         if len(FH.mismatched_idx)>0:
            # there is a delta exit = 0
            exit(0)
         else:
            # there is no delta exit != 0
            exit(1)

      # feedback via exit code if there was a hash update.
      if FH.save_hashes is True:
         exit(1)
      else:
         exit(0)

   elif args.verify_against is not False and False is True:

      # verify branch and option to write delta file and option for remote delta
      FH.verify_against(hash_filename=args.verify_against,write_delta_file=args.delta_file,chunk_limit=args.chunk_limit,remote_delta=args.remote_delta)
      if args.delta_file is not False:
         if len(FH.mismatched_idx)>0:
            # there is a delta exit = 0
            exit(0)
         else:
            # there is no delta exit != 0
            exit(1)

   elif args.apply_delta_file is not False:
      print(f"- file to be patched: {args.inputfile}")
      print(f"- delta file:         {args.apply_delta_file}")
      FH.patch(delta_file=args.apply_delta_file)
      pass

   else:
      raise Exception("Unknown execution mode")

#exit(0)
