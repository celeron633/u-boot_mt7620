/**
 * \addtogroup httpd
 * @{
 */

/**
 * \file
 * HTTP server read-only file system code.
 * \author Adam Dunkels <adam@dunkels.com>
 *
 * A simple read-only filesystem. 
 */
 
/*
 * Copyright (c) 2001, Swedish Institute of Computer Science.
 * All rights reserved. 
 *
 * Redistribution and use in source and binary forms, with or without 
 * modification, are permitted provided that the following conditions 
 * are met: 
 * 1. Redistributions of source code must retain the above copyright 
 *    notice, this list of conditions and the following disclaimer. 
 * 2. Redistributions in binary form must reproduce the above copyright 
 *    notice, this list of conditions and the following disclaimer in the 
 *    documentation and/or other materials provided with the distribution. 
 * 3. Neither the name of the Institute nor the names of its contributors 
 *    may be used to endorse or promote products derived from this software 
 *    without specific prior written permission. 
 *
 * THIS SOFTWARE IS PROVIDED BY THE INSTITUTE AND CONTRIBUTORS ``AS IS'' AND 
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE INSTITUTE OR CONTRIBUTORS BE LIABLE 
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS 
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY 
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
 * SUCH DAMAGE. 
 *
 * This file is part of the lwIP TCP/IP stack.
 * 
 * Author: Adam Dunkels <adam@sics.se>
 *
 * $Id: fs.c,v 1.7.2.3 2003/10/07 13:22:27 adam Exp $
 */

#include "uip.h"
#include "httpd.h"
#include "fs.h"
#include "fsdata.h"

#include "fsdata.c"

/* Defined in net/httpd.c - see the long comment there.  The pointers
   stored inside the fsdata table are link time addresses that U-Boot's
   relocation does not fix up, so every one of them has to be adjusted
   before it is dereferenced.  FS_ROOT and string literals do not, they
   are resolved through the GOT. */
extern unsigned long HttpdRelocOff(void);

#define FS_FIXUP(p, type) \
	((type)((p) == 0 ? 0 : (unsigned long)(p) + HttpdRelocOff()))

#ifdef FS_STATISTICS
#if FS_STATISTICS == 1
static u16_t count[FS_NUMFILES];
#endif /* FS_STATISTICS */
#endif /* FS_STATISTICS */

/*-----------------------------------------------------------------------------------*/
static u8_t
fs_strcmp(const char *str1, const char *str2)
{
  /* i used to be a u8_t, which wraps back to 0 after 255 characters and
     turns this into an endless loop whenever both strings run that long
     without a terminator - e.g. when f->name is a corrupted pointer. */
  unsigned int i;

  for(i = 0; i < 64; ++i) {
    if(str2[i] == 0 ||
       str1[i] == '\r' ||
       str1[i] == '\n') {
      return 0;
    }

    if(str1[i] != str2[i]) {
      return 1;
    }
  }

  return 1;
}
/*-----------------------------------------------------------------------------------*/
int
fs_open(const char *name, struct fs_file *file)
{
#ifdef FS_STATISTICS
#if FS_STATISTICS == 1
  u16_t i = 0;
#endif /* FS_STATISTICS */
#endif /* FS_STATISTICS */
  struct fsdata_file_noconst *f;
  unsigned int guard;

  for(f = (struct fsdata_file_noconst *)FS_ROOT, guard = 0;
      f != NULL;
      f = FS_FIXUP(f->next, struct fsdata_file_noconst *), ++guard) {

    /* The table is a static linked list of exactly FS_NUMFILES entries.
       If ->next ever points somewhere else we would walk random memory
       and hand a wild ->data pointer back to the caller, so stop. */
    if(guard >= FS_NUMFILES || f->name == NULL || f->data == NULL) {
      printf("## Error: fsdata chain corrupted at entry %u (f=0x%08X)!\n",
	     guard, (unsigned int)f);
      return 0;
    }

    if(fs_strcmp(name, FS_FIXUP(f->name, char *)) == 0) {
      file->data = FS_FIXUP(f->data, char *);
      file->len = f->len;
#ifdef FS_STATISTICS
#if FS_STATISTICS == 1
      ++count[i];
#endif /* FS_STATISTICS */
#endif /* FS_STATISTICS */
      return 1;
    }
#ifdef FS_STATISTICS
#if FS_STATISTICS == 1
    ++i;
#endif /* FS_STATISTICS */
#endif /* FS_STATISTICS */

  }
  return 0;
}
/*-----------------------------------------------------------------------------------*/
void
fs_init(void)
{
#ifdef FS_STATISTICS
#if FS_STATISTICS == 1
  u16_t i;
  for(i = 0; i < FS_NUMFILES; i++) {
    count[i] = 0;
  }
#endif /* FS_STATISTICS */
#endif /* FS_STATISTICS */
}
/*-----------------------------------------------------------------------------------*/
#ifdef FS_STATISTICS
#if FS_STATISTICS == 1  
u16_t fs_count
(char *name)
{
  struct fsdata_file_noconst *f;
  u16_t i;

  i = 0;
  for(f = (struct fsdata_file_noconst *)FS_ROOT;
      f != NULL;
      f = (struct fsdata_file_noconst *)f->next) {

    if(fs_strcmp(name, f->name) == 0) {
      return count[i];
    }
    ++i;
  }
  return 0;
}
#endif /* FS_STATISTICS */
#endif /* FS_STATISTICS */
/*-----------------------------------------------------------------------------------*/
