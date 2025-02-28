#!/usr/bin/env python3

# copyright 2024 by gh-hastmu@gmx.de
# homed at: https://github.com/hastmu/avahi-backup

# defaults
from pathlib import Path

_CFG={
   "default_hash_basedir": str(Path.home())+"/.cache/avahi-backup/hashes"
}

import atexit
import time
import pickle
import math

import argparse

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

group = parser.add_argument_group('Debugging...')
group.add_argument("--show-hashes", help="lists stored hashes in hash file", type=str, default=False)

args = parser.parse_args()

# exit function
def save_hash_file():
   FH.save_hash()

import signal
import sys
import base64
import threading
import multiprocessing

def sigterm_handler(signal, _stack_frame):
    # Raises SystemExit(0):
    sys.exit(2)

signal.signal(signal.SIGTERM, sigterm_handler)

import os
import hashlib

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
            print(f"chunk processed {self.abs_chk_reads} at {self.report()}", end="\r")
         else:
            print(f"chunk processed {self.abs_chk_reads} of {(self.abs_chk_reads*100/(self.max_size/size)):3.2f}% at {self.report()} with Threads[{threading.active_count()}|{len(multiprocessing.active_children())}]", end="\r")

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
      result=self.size_bw(self.min)+" - " + self.size_bw(self.avg) + " - " + self.size_bw(self.max)
      return result

class FileHasher():

   chunk_file_version = "v1.0.3"
   patch_file_version = "v1.0.0"

   def __init__(self,* , inputfile=False, hashfile=False, chunk_size=8192, hash_method="flat", debug=False):

      # defaults
      self.threads=[]
      self.lock_reading=threading.Lock()
      self.lock_update_idx=threading.Lock()
      self.hash_obj={}
      self.mtime=0
      self.save_hashes=False
      self._debug=debug

      # method
      # TODO: conclude on method if needed
      self.method=hash_method
      self.hash_file_def=f"hash_file_"+self.method
      if hasattr(self, self.hash_file_def) and callable(func := getattr(self, self.hash_file_def)):
         pass
      else:
         raise Exception("Unknown hash function")    

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

   def _read_file_in_chunks(self,file_object, *,chunk_size=8192,seek_chunk=-1):

      if seek_chunk != -1:
         file_object.seek(seek_chunk*chunk_size)

      while True:
         data = file_object.read(chunk_size)
         if not data:
               break
         yield bytes(data)

   def hash_file_flat(self,piece):
      # hash each chk
      data=hashlib.sha256(piece)
      # convert to string
      self.hash_obj[self.chk]=data.hexdigest()

   def update_hash_idx(self, *, chunk, new_hash):

      old_hash=self.hash_obj.get(chunk,False)
      if old_hash == False or old_hash != new_hash:
         # only add and flag as updated if there is a real change.
         self.debug(type="INFO:update_hash_idx",msg=f"- update {chunk} [{self.chunk_size*chunk}-{self.chunk_size*(chunk+1)}/{self.inputfile_stats.st_size}] with new[{new_hash}] old[{old_hash}]- length {self.hash_obj.__len__()}")
         self.lock_update_idx.acquire()
         self.hash_obj[chunk]=new_hash
         self.lock_update_idx.release()
         self.save_hashes=True
      else:
         self.debug(type="INFO:update_hash_idx",msg=f"- same   {chunk} with [{new_hash}]")

   def hash_thread(self, *, cpu=-1,Read_file=False):

      self.debug(type="INFO:hash_thread",msg=f"- hashing thread cpu[{cpu}] - start")

      with open(self.inputfile,"rb") as f:
         while self.active is True or len(self.chunk_buffer[cpu]) > 0:
            # process buffer
            for chunk in list(self.chunk_buffer[cpu]):
               #print(f"- processing cpu[{cpu}] chunk[{chunk}]")
               if Read_file is True:
                  self.debug(type="INFO:hash_thread",msg=f"- reading cpu[{cpu}] chunk[{chunk}] length[{len(self.chunk_buffer[cpu])}]")
                  piece=self._read_one_chunk(f,chunk_size=self.chunk_size,seek_chunk=chunk,lock=False)
               else:
                  self.debug(type="INFO:hash_thread",msg=f"- processing cpu[{cpu}] chunk[{chunk}] length[{len(self.chunk_buffer[cpu])}]")
                  piece=self.chunk_buffer[cpu].get(chunk,False)
               if piece is not False:
                  del self.chunk_buffer[cpu][chunk]
                  data=hashlib.sha256(piece)
                  self.update_hash_idx(chunk=chunk,new_hash=data.hexdigest())

            time.sleep(0.001)

      self.debug(type="INFO:hash_thread",msg=f"- hashing thread cpu[{cpu}] - end")
      

   def hash_file(self, *, incremental=True,threading_mode=0):
      # update stats
      self._refresh_inputfile_stats()
      # hash
      # TODO: Revisit incremental with the new index missing scheme.
      if incremental is False:
         self.hash_obj={}

      self.chk=int(0)
      with open(self.inputfile,"rb") as f:
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

         self.debug(type="INFO:hash_file",msg="- Theading mode: "+str(threading_mode))

         if threading_mode == 0:
            # non-threading mode

            for chunk in range(0,self.max_chk):
               old_data=self.hash_obj.get(chunk,False)
               if old_data is False:
                  # missing hash
                  self.debug(type="INFO:hash_file",msg=f"- missing chunk[{chunk}]")
                  try:
                     piece=self._read_one_chunk(f,chunk_size=self.chunk_size,seek_chunk=chunk)
                     data=hashlib.sha256(piece)
                     self.update_hash_idx(chunk=chunk,new_hash=data.hexdigest())
                     read_speed.update_run(self.chunk_size)
                  except:
                     self.debug(type="INFO:hash_file",msg="  - failed -> exception")
                     pass
               else:
                  #self.debug(type="INFO:hash_file",msg=f"- already chunk[{chunk}] = {self.hash_obj[chunk]}")
                  pass

         elif threading_mode == 1 or threading_mode == 2:
            # only hashing

            # BROKEN-doest not build all chunks.

            self.chunk_buffer={}
            self.thread={}
            self.active=True

            max_cpu_count=multiprocessing.cpu_count()
            cpu_count=max_cpu_count

            for cpu in range(0,cpu_count):
               self.chunk_buffer[cpu]={}
               if threading_mode == 1:
                  self.thread[cpu]=threading.Thread(target=self.hash_thread,kwargs={"cpu":cpu, "Read_file":True})
               else:
                  self.thread[cpu]=threading.Thread(target=self.hash_thread,kwargs={"cpu":cpu, "Read_file":False})
               self.thread[cpu].start()

            next_cpu=0
            target_bw_s=10*1024*1024*1024 #  10GiB/s
            chunks_per_s=target_bw_s / self.chunk_size
            time_per_chunk=1/chunks_per_s
            print(f"- time per chunk at target bw: {time_per_chunk} sec")
            max_queue_length=32
            min_queue_length=8
            immune_count=0
            sensor=cpu_count
            self.chunk_buffer[sensor]=[]
            for chunk in range(0,self.max_chk):

               #print(f"- time per chunk at target bw: {time_per_chunk} sec")
               time.sleep(time_per_chunk) # keep back to not overload queues

               old_data=self.hash_obj.get(chunk,False)
               if old_data is False:
                  # missing hash - guidance or data for threads
                  self.debug(type="INFO:hash_file",msg=f"- missing chunk[{chunk}]")
                  if threading_mode == 1:
                     self.chunk_buffer[next_cpu][chunk]=True
                     # if queue length is over the limit then reduce the active filled threads
                  else:
                     self.chunk_buffer[next_cpu][chunk]=self._read_one_chunk(f,chunk_size=self.chunk_size,seek_chunk=chunk)

                  if len(self.chunk_buffer[next_cpu]) > max_queue_length:
                     time_per_chunk=time_per_chunk*2
                     print(f"- new time per chunk: {time_per_chunk} sec")

#                     if cpu_count > 1:
#                        cpu_count=cpu_count-1
#                        if min_queue_length > 0:
#                           min_queue_length=min_queue_length-1
#                        print("- reduced active queues...")
                  elif len(self.chunk_buffer[next_cpu]) < min_queue_length and immune_count == 0:
                     time_per_chunk=time_per_chunk*0.9
                     print(f"- new time per chunk: {time_per_chunk} sec")
#                     if cpu_count < max_cpu_count:
#                        max_queue_length=max_queue_length*1.1
#                        #min_queue_length=max_queue_length
#                        print("- adding active queues...")
#                        cpu_count=cpu_count+1
#                        immune_count=int(2*max_queue_length)

                  # if time becomes to high, the io-system is to slow, therefore reduce threads
                  if time_per_chunk > 0.250 and len(self.chunk_buffer[sensor]) == 0:
                     sensor=cpu_count-1
                     if cpu_count > 1:
                        cpu_count=int(cpu_count/2)
                     print(f"- cut down threads: {cpu_count}")
                  else:
                     print(f"- sensor: {sensor} {len(self.chunk_buffer[sensor])}")


                  if immune_count > 0:
                     immune_count=immune_count-1

#                  info=""
                  min_len=False
                  for cpu in range(0,cpu_count):
                     if len(self.chunk_buffer[cpu]) < min_len or min_len is False:
                        next_cpu=cpu
                        min_len=len(self.chunk_buffer[cpu])
#                     info=f" cpu[{cpu:>2}] len[{len(self.chunk_buffer[cpu]):>4}] {info}"
#                  print(f"- stat {info}\r",end="")

                  read_speed.update_run(self.chunk_size)
#                  time.sleep(1)
               else:
                  #self.debug(type="INFO:hash_file",msg=f"- already chunk[{chunk}] = {self.hash_obj[chunk]}")
                  pass

            self.active=False

            for cpu in range(0,multiprocessing.cpu_count()):
               self.thread[cpu].join()
            
         else:
            raise Exception("threading mode unknown")
            


      print(f"\33[2K\r",end='\r')

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
      if write_delta_file != False:
         patch_data={
            "version": self.patch_file_version,
            "stats" : self.inputfile_stats,
            "chunk_size": self.chunk_size,
            "mismatch_idx": [], 
            "mismatch_idx_hashes": {} 
         }
      # remote delta
      if remote_delta != False:
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

      if verify != False:
         loaded_hashes=len(verify["hashes"])
         # init counts
         count=match=mismatch=0
         self.mismatched_idx=[]
         self.mismatched_idx_hashes={}

         if write_delta_file != False:
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
               if input_hash == False:
                  if read_speed == False:
                     read_speed=speed(max_size=self.inputfile_stats.st_size,start_chunk=self.chk)
                  if source_file == False:
                     source_file=open(self.inputfile,"rb")
                     source_file.seek(0)
                  # we need to hash the file again.
                  # TODO: make that method agnostic.
                  if remote_delta == False:
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
               if input_hash == compare_hash and input_hash != False:
                  match=match+1
               else:
                  mismatch=mismatch+1
                  self.debug(type="INFO:verify_against",msg="delta at chk["+str(self.chk)+"] SRC["+str(input_hash)+"] VERIFY["+str(compare_hash)+"]")
                  
                  if write_delta_file != False or remote_delta != False:
                     if source_file == False:
                        source_file=open(self.inputfile,"rb")
                        source_file.seek(0)
                     self.mismatched_idx.append(self.chk)
                     self.mismatched_idx_hashes[self.chk]=input_hash
                     # seek source file
                     if data_chunk == False:
                        self.debug(type="INFO:verify_against",msg="re-read inputfile chk["+str(self.chk)+"] hash["+str(input_hash)+"]")
                        source_file.seek(self.chk*self.chunk_size)
                        data_chunk=source_file.read(self.chunk_size)
                     
                     if write_delta_file != False:
                        delta_file.write(data_chunk)
                     if remote_delta != False:
                        send_data={
                           "chunk": self.chk,
                           "chunk_data": data_chunk,
                           "chunk_hash": input_hash
                        }
                        self.send_msg(type="chunk",data=send_data)

                     self.debug(type="INFO:verify_against",msg="write delta file chk["+str(self.chk)+"] data-length["+str(len(data_chunk))+"]")

         #print(f"\33[2K\r",end='\r')
         print(f"verify [#{loaded_hashes}:{hash_filename}] loaded - M[#{match}:!#{mismatch}]")

         if write_delta_file != False:
            if source_file != False:
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
      if target_file == False:
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

      if stats != False:
         with open(self.inputfile,"r+b") as target_file:
            target_file.truncate(stats.st_size)

         # apply/update metadata
         os.chown(self.inputfile,stats.st_uid,stats.st_gid)
         os.utime(self.inputfile,ns=(stats.st_atime_ns,stats.st_mtime_ns))

   def patch(self, *, delta_file=False):

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
      if self.save_hashes == True:
         print(f"{self.loaded_hashes} - updated - hashfile[{len(self.hash_obj)}:{self.hashfile}] - chunk-size[{self.chunk_size}]")
      else:
         print(f"{self.loaded_hashes} - unchanged - hashfile[{len(self.hash_obj)}:{self.hashfile}] - chunk-size[{self.chunk_size}]")

   def debug(self,*,type="INFO",msg="-"):
      if self._debug == True:
         print(f"[{type}]: {msg}")

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
      
      self.feedback()

version="1.0.18"

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
   FH=FileHasher(inputfile=args.inputfile, chunk_size=args.min_chunk_size, hashfile=args.hashfile,debug=args.debug)
   atexit.register(save_hash_file)

   import paramiko
   ssh = paramiko.SSHClient()
   ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
   if args.remote_password == False:
      private_key = paramiko.RSAKey.from_private_key_file(args.remote_ssh_key)
      ssh.connect(args.remote_hostname, username=args.remote_username, pkey=private_key, look_for_keys=False)
   else:
      ssh.connect(args.remote_hostname, username=args.remote_username, password=args.remote_password)
   
   # skip version check if already done. set FILEHASHER_SKIP_VERSION
   if os.environ.get("FILEHASHER_SKIP_VERSION",False) == False:
      ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command("filehasher.py --version")
      remote_version=ssh_stdout.readline().strip()
   else:
      remote_version=version

   if remote_version == version:
      with open(FH.hashfile,"rb") as handle:
         ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command("filehasher.py --inputfile \""+args.remote_src_filename+"\" --min-chunk-size "+str(FH.chunk_size)+" --verify-against - --remote-delta")
         ssh_stdin.write(handle.read())

         patch_data=FH.receive_msg(pipe=ssh_stdout)
         #print(patch_data)
         if patch_data["type"] == "metadata":
            FH.apply_stats(stats=patch_data["stats"])
         else:
            print(patch_data)
            raise Exception("no metadata sent")
            exit(1)

         loop=True
         while loop:

            # read next
            data=FH.receive_msg(pipe=ssh_stdout)

            if data["type"] == "chunk":
               print(f"chunk - "+str(data["chunk"]))
               FH.patch_chk(chunk=data["chunk"],chunk_data=data["chunk_data"],chunk_hash=data["chunk_hash"])
            else:
               loop=False

         if patch_data["type"] == "metadata":
            FH.apply_stats(stats=patch_data["stats"])
         else:
            print(patch_data)
            raise Exception("no metadata sent")
            exit(1)

   else:
      raise Exception("local and remote version do not match")

elif args.inputfile is False:
   print("please use -h for help.")
   exit(0)
else:
   # print (args)

   FH=FileHasher(inputfile=args.inputfile, chunk_size=args.min_chunk_size, hashfile=args.hashfile,debug=args.debug)
   if args.report_used_hashfile is True:
      print(f"{FH.hashfile}")
      exit(0)

   atexit.register(save_hash_file)

   if args.verify_against is False and args.apply_delta_file is False:
      # normal hashing 
      if args.force_refresh is True:
         FH.hash_file(incremental=False,threading_mode=args.thread_mode)
      else:
         FH.hash_file(incremental=True,threading_mode=args.thread_mode)

      # feedback via exit code if there was a hash update.
      if FH.save_hashes is True:
         exit(1)
      else:
         exit(0)

   elif args.verify_against is not False:
      # verify branch
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
