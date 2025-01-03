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

   chunk_file_version = "v1.0.0"

   def __init__(self,* , inputfile="", hashfile=False, chunk_size=8192, hash_method="flat"):

      # defaults
      self.hash_obj={}
      self.mtime=0
      self.save_hashes=False

      # method
      # TODO: conclude on method if needed
      self.method=hash_method
      self.hash_file_def=f"hash_file_"+self.method
      if hasattr(self, self.hash_file_def) and callable(func := getattr(self, self.hash_file_def)):
         pass
      else:
         raise Exception("Unknown hash function")    

      # get inputfile, stats and check if exists.
      self.inputfile=inputfile
      if os.path.isfile(self.inputfile):
         self._refresh_inputfile_stats()
      else:
         raise Exception("Input file not found.") 

      self.chunk_size=chunk_size
      self.max_chk=math.ceil(self.inputfile_stats.st_size/self.chunk_size)

      if hashfile == False:
         # new
         self.hashfile_abspath=os.path.abspath(self.inputfile)
         self.hashfile_hashedname=hashlib.sha512(self.hashfile_abspath.encode()).hexdigest()
         os.makedirs(_CFG["default_hash_basedir"]+"/"+self.hashfile_hashedname[0:2]+"/"+self.hashfile_hashedname[2:4], exist_ok=True)
         self.hashfile=_CFG["default_hash_basedir"]+"/"+self.hashfile_hashedname[0:2]+"/"+self.hashfile_hashedname[2:4]+"/"+self.hashfile_hashedname
         # migrate old ones
         if os.path.isfile(self.inputfile+".hash."+str(self.chunk_size)):
            import shutil
            shutil.move(self.inputfile+".hash."+str(self.chunk_size),self.hashfile)
      else:
         self.hashfile=hashfile

      # self.load_hashes = initial | not-loaded(outdated) | not-loaded(wrong chunk-size) | loaded based on state

      if os.path.isfile(self.hashfile):
         with open(self.hashfile, 'rb') as handle:
            data = pickle.load(handle)
         
         # check version
         hashfile_format_version=data.get("version",False)
         hashfile_inputfile=data.get("inputfile",False)

         # version check
         if  hashfile_format_version == False or hashfile_format_version != self.chunk_file_version:
            # version does not match
            self.loaded_hashes="not-loaded(version)"
            self.save_hashes=True
         elif data["mtime"] != self.inputfile_stats.st_mtime:
            self.loaded_hashes="not-loaded(outdated)"
            self.save_hashes=True
         elif data["chunk_size"] != self.chunk_size:
            # wrong chunk_size
            self.loaded_hashes="not-loaded(wrong chunk-size)"
            self.save_hashes=True
         elif hashfile_inputfile != False and hashfile_inputfile != os.path.abspath(self.inputfile):
            self.loaded_hashes="not-loaded(wrong-inputfile)"
            self.save_hashes=True
         else:
            self.loaded_hashes="loaded"
            self.hash_obj=data["hashes"]
            #print(self.hash_obj)
      else:
         self.loaded_hashes="initial"


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

      read_speed=False
      source_file=False
      if os.path.isfile(hash_filename):
         # create hash if outdated
         if len(self.hash_obj) == 0:
#            self.hash_file(incremental=True)
            self.save_hashes=True
            self.hash_obj={}
         # prepare delta file

         with open(hash_filename, 'rb') as handle:
            self.verify_data = pickle.load(handle)
            loaded_hashes=len(self.verify_data["hashes"])
            #loaded_chunk_size=loaded_hashes["chunk_size"]
            # TODO: check chunk-size
#            self.loaded_hashes=self.loaded_hashes+f"- verify [{loaded_hashes}:{hash_filename}]"

         count=0
         match=0
         mismatch=0
         self.mismatched_idx=[]

         if write_delta_file != False:
            delta_file=open(write_delta_file, 'wb')
            print(f"- write delta files {write_delta_file}...")

         inputfile_handle=False
         for self.chk in range(0,self.max_chk):

            if chunk_limit != False and mismatch >= chunk_limit:
               # break if we reached chunk_limit
               break
            else:

               # get hashes and compare

               input_hash=self.hash_obj.get(self.chk,False)
               compare_hash=self.verify_data["hashes"].get(self.chk,False)
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
                  #self.hash_obj[self.chk]=self.hash_obj.get(self.chk,False)
                  input_hash=self.hash_obj[self.chk]
                  self.save_hashes=True
   #               print(f"new hash {self.hash_obj[self.chk]} for chk {self.chk}")

               if compare_hash == False:
                  raise Exception("compare hash not available")

               # compare
               if input_hash == compare_hash:
                  match=match+1
                  #print(f"M", end="")
                  #print(f"match at {self.chk}")
                  #print(f"SRC[{input_hash}]")
                  #print(f"TRG[{compare_hash}]")
               else:
                  mismatch=mismatch+1
                  if write_delta_file != False:
                     if source_file == False:
                        source_file=open(self.inputfile,"rb")
                        source_file.seek(0)
                     self.mismatched_idx.append(self.chk)
                     # seek source file
                     if data_chunk == False:
                        #print(f"R", end="")
                        print(f"- refresh read chk {self.chk}...")
                        source_file.seek(self.chk*self.chunk_size)
                        data_chunk=source_file.read(self.chunk_size)
                     delta_file.write(data_chunk)

                  #print(f"!", end="")
                  print(f"mismatch at {self.chk}")
                  print(f"SRC[{input_hash}]")
                  print(f"TRG[{compare_hash}]")

         #print(f"\33[2K\r",end='\r')
         print(f"verify [#{loaded_hashes}:{hash_filename}] loaded - M[#{match}:!#{mismatch}]")

         if write_delta_file != False:
            if source_file != False:
               source_file.close()
            delta_file.close()
            if mismatch > 0:
               # TODO: store also chunk-size 
               # TODO: store size of file to enable truncation.
               with open(write_delta_file+".hash", 'wb') as handle:
                  pickle.dump(self.mismatched_idx, handle, protocol=pickle.HIGHEST_PROTOCOL)
            else:
               os.remove(write_delta_file)
      else:
         raise Exception("can not read hash file")

   def patch(self, *, delta_file=False):

      if delta_file == False:
         raise Exception("no delta file provided")
      elif os.path.isfile(delta_file) == False or os.path.isfile(delta_file+".hash") == False:
         raise Exception("delta file do not exist or not complete")
      else:
         # read hash file
         # TODO: add meta data like file format version + chunk size to check if mismatches would corrupt the target file

         with open(delta_file+".hash", 'rb') as handle:
            patch_chk_list = pickle.load(handle)

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

version="1.0.9"

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

   FH=FileHasher(inputfile=args.inputfile, chunk_size=args.min_chunk_size, hashfile=args.hashfile)
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
