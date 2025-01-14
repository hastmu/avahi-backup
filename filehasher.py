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

group = parser.add_argument_group('Hashing...')
group.add_argument("--inputfile", help="file which should be hashed.", type=str, default=False)
group.add_argument("--min-chunk-size", help="smallest chunk for hashing.", type=int, default=8192)
group.add_argument("--build-only", help="build only - no compare", type=bool, default=True)
group.add_argument("--force-refresh", action='store_true', help="refresh also available hashes in build-only mode")
group.add_argument("--hashfile", help="define which hashfile is used",default=False)

group = parser.add_argument_group('Verifying...')
group.add_argument("--verify-against", help="hashed which should be verified for matching", type=str, default=False)
group.add_argument("--delta-file", help="store deltas to this file for patching", type=str, default=False)
group.add_argument("--chunk-limit", help="limit written deltas per run", type=int, default=False)
group = parser.add_argument_group('Patching...')
group.add_argument("--apply-delta-file", help="patches the inputfile with the content of the delta file", type=str, default=False)

group = parser.add_argument_group('Debugging...')
group.add_argument("--show-hashes", help="lists stored hashes in hash file", type=str, default=False)

args = parser.parse_args()

# exit function
def save_hash_file():
   FH.save_hash()

import signal
import sys

def sigterm_handler(_signo, _stack_frame):
    # Raises SystemExit(0):
    sys.exit(0)

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
         if self.max_size == False:
            print(f"chunk processed {self.abs_chk_reads} at {self.report()}", end="\r")
         else:
            print(f"chunk processed {self.abs_chk_reads} of {(self.abs_chk_reads*100/(self.max_size/size)):3.2f}% at {self.report()}", end="\r")

         # new cycle
         self.s_time=time.time()

   def update(self,value):
      if self.min == False:
         self.min=value
      elif self.min > value:
         self.min=value

      if self.max == False:
         self.max=value
      elif value > self.max:
         self.max=value

      if self.avg == False:
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

   chunk_file_version = "v1.0.2"
   patch_file_version = "v1.0.0"

   def __init__(self,* , inputfile=False, hashfile=False, chunk_size=8192, hash_method="flat", debug=False):

      # defaults
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
      if inputfile != False:
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

      if hashfile == False:
         # new
         self.hashfile_hashedname=hashlib.sha512(self.inputfile_abspath.encode()).hexdigest()
         os.makedirs(_CFG["default_hash_basedir"]+"/"+self.hashfile_hashedname[0:2]+"/"+self.hashfile_hashedname[2:4], exist_ok=True)
         self.hashfile=_CFG["default_hash_basedir"]+"/"+self.hashfile_hashedname[0:2]+"/"+self.hashfile_hashedname[2:4]+"/"+self.hashfile_hashedname
      else:
         self.hashfile=hashfile

      # self.load_hashes = initial | not-loaded(outdated) | not-loaded(wrong chunk-size) | loaded based on state

      data=self.load_hash(hashfile=self.hashfile, extended_tests=True)

      if data == False:
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

   def _read_file_in_chunks(self,file_object,chunk_size=8192):
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

   def hash_file(self, *, incremental=True):
      # update stats
      self._refresh_inputfile_stats()
      # hash
      if incremental == False:
         self.hash_obj={}

      self.chk=int(0)
      with open(self.inputfile,"rb") as f:
         if incremental == True:
            self.chk=len(self.hash_obj)
            self.loaded_hashes=self.loaded_hashes+" - inc["+str(self.chk)+"-"+str(self.max_chk)+"]"
            f.seek(self.chk*self.chunk_size)
         else:
            f.seek(0)

         read_speed=speed(max_size=self.inputfile_stats.st_size,start_chunk=self.chk)

         for piece in self._read_file_in_chunks(f,self.chunk_size):
            self.save_hashes=True
            read_speed.update_run(self.chunk_size)
            # hash
            data=hashlib.sha256(piece)
            # convert to string
            self.hash_obj[self.chk]=data.hexdigest()
            self.chk=self.chk+1
      print(f"\33[2K\r",end='\r')

   def verify_against(self,*, hash_filename, write_delta_file=False, chunk_limit=False):

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
                  if write_delta_file != False:
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
                     delta_file.write(data_chunk)
                     self.debug(type="INFO:verify_against",msg="write delta file chk["+str(self.chk)+"] data-length["+str(len(data_chunk))+"]")

         #print(f"\33[2K\r",end='\r')
         print(f"verify [#{loaded_hashes}:{hash_filename}] loaded - M[#{match}:!#{mismatch}]")

         if write_delta_file != False:
            if source_file != False:
               source_file.close()
            delta_file.close()
            if mismatch > 0:
               patch_data["version"]=self.chunk_file_version
               patch_data["mtime"]=self.inputfile_stats.st_mtime
               patch_data["size"]=self.inputfile_stats.st_size
               patch_data["uid"]=self.inputfile_stats.st_uid
               patch_data["gid"]=self.inputfile_stats.st_gid
               patch_data["chunk_size"]=self.chunk_size
               patch_data["mismatch_idx"]=self.mismatched_idx
               patch_data["mismatch_idx_hashes"]=self.mismatched_idx_hashes
               with open(write_delta_file+".hash", 'wb') as handle:
                  pickle.dump(patch_data, handle, protocol=pickle.HIGHEST_PROTOCOL)
            else:
               os.remove(write_delta_file)
      else:
         raise Exception("can not read hash file")

      self.debug(type="INFO:verify_against",msg="Done")

   def patch(self, *, delta_file=False):

      if delta_file == False:
         raise Exception("no delta file provided")
      elif os.path.isfile(delta_file) == False or os.path.isfile(delta_file+".hash") == False:
         raise Exception("delta file do not exist or not complete")
      else:
         # read hash file
         # DONE: add meta data like file format version + chunk size to check if mismatches would corrupt the target file
         # - patch_data is there evaluate it and apply stats to target file.

         with open(delta_file+".hash", 'rb') as handle:
            patch_data = pickle.load(handle)

         # TODO: patch_data["mismatch_idx_hashes"]
         # TODO: stats.
         if patch_data["version"] != self.patch_file_version:
            raise Exception("delta file version ["+str(patch_data["version"])+"] mismatch self["+str(self.patch_file_version)+"]")

         # check chunk_size
         if patch_data["chunk_size"] != self.chunk_size:
            raise Exception("Chunk size mismatch between delta file ["+str(patch_data["chunk_size"])+"] and file ["+str(self.chunk_size)+"] to patch. Fatal.")

         patch_chk_list=patch_data["mismatch_idx"]
         print(f"- {len(patch_chk_list)} chunks to patch...")

         with open(delta_file, 'rb') as patch_data_file:
            with open(self.inputfile, 'r+b') as target_file:
               # TODO: truncate to size.
               for idx in patch_chk_list:
                  print(f"  - patch chk {idx}")
                  chk_data=patch_data_file.read(self.chunk_size)
                  target_file.seek(idx * self.chunk_size)
                  data=hashlib.sha256(chk_data)
                  # convert to string
                  self.hash_obj[idx]=data.hexdigest()
                  self.save_hashes=True
                  target_file.write(chk_data)
         
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

   def load_hash(self,*, hashfile=False, extended_tests=False):

      self.loaded_hash_error="-"
      if hashfile != False:
         self.debug(type="INFO:load_hash",msg="Loading hashfile cwd["+os.getcwd()+"]"+hashfile)
         if os.path.isfile(hashfile):
            with open(hashfile, 'rb') as handle:
               data = pickle.load(handle)
            
            try:
               # check version
               if data["version"] != self.chunk_file_version:
                  self.debug(type="INFO:load_hash",msg="version mismatch self["+str(self.chunk_file_version)+"] file["+data["version"]+"]")
                  self.loaded_hash_error="not-loaded(version)"
                  return False
               # check chunk_size
               if data["chunk_size"] != self.chunk_size:
                  self.debug(type="INFO:load_hash",msg="chunk_size mismatch self["+str(self.chunk_size)+"] file["+data["chunk_size"]+"]")
                  self.loaded_hash_error="not-loaded(wrong chunk-size)"
                  return False
               
               # extendend checks
               if extended_tests == True:
                  # check if size matches
                  if data["size"] != self.inputfile_stats.st_size:
                     self.debug(type="INFO:load_hash",msg="size mismatch self["+str(self.size)+"] file["+data["size"]+"]")
                     self.loaded_hash_error="not-loaded(wrong-size)"
                     return False
                  # check mtime
                  if data["mtime"] != self.inputfile_stats.st_mtime:
                     self.debug(type="INFO:load_hash",msg="mtime mismatch self["+str(self.inputfile_stats.st_mtime)+"] file["+data["mtime"]+"]")
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
         data["mtime"]=self.inputfile_stats.st_mtime
         data["size"]=self.inputfile_stats.st_size
         
         # save
         with open(self.hashfile, 'wb') as handle:
            pickle.dump(data, handle, protocol=pickle.HIGHEST_PROTOCOL)
      
      self.feedback()

version="1.0.11"

if args.version == True:
   print(f"{version}")
elif args.show_hashes != False:
   if os.path.isfile(args.show_hashes):
      #print(f"load hashes from: {args.show_hashes}")
      with open(args.show_hashes, 'rb') as handle:
         data = pickle.load(handle)
      import json
      print(json.dumps(data))
   else:
      raise Exception("can not load hash file")

else:
   # print (args)

   FH=FileHasher(inputfile=args.inputfile, chunk_size=args.min_chunk_size, hashfile=args.hashfile,debug=args.debug)
   if args.report_used_hashfile == True:
      print(f"{FH.hashfile}")
      exit(0)

   atexit.register(save_hash_file)

   if args.verify_against == False and args.apply_delta_file == False:
      # normal hashing 
      if args.force_refresh == True:
         FH.hash_file(incremental=False)
      else:
         FH.hash_file(incremental=True)

      # feedback via exit code if there was a hash update.
      if FH.save_hashes == True:
         exit(1)
      else:
         exit(0)

   elif args.verify_against != False:
      # verify branch
      FH.verify_against(hash_filename=args.verify_against,write_delta_file=args.delta_file,chunk_limit=args.chunk_limit)
      if args.delta_file != False:
         if len(FH.mismatched_idx)>0:
            # there is a delta exit = 0
            exit(0)
         else:
            # there is no delta exit != 0
            exit(1)

   elif args.apply_delta_file != False:
      print(f"- file to be patched: {args.inputfile}")
      print(f"- delta file:         {args.apply_delta_file}")
      FH.patch(delta_file=args.apply_delta_file)
      pass

   else:
      raise Exception("Unknown execution mode")

exit(0)
