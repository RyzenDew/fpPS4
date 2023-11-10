unit kern_stub;

{$mode ObjFPC}{$H+}
{$CALLING SysV_ABI_CDecl}

interface

uses
 mqueue;

{.$DEFINE chunk_alloc}

const
 m_header=WORD($C3C3);

 m_free__chunk=1;
 m_first_chunk=2;
 m_last__chunk=4;

type
 p_stub_chunk=^stub_chunk;
 stub_chunk=packed record
  head     :WORD;
  flags    :WORD;
  prev_size:Integer;
  curr_size:Integer;
  refs     :Integer;
  link     :TAILQ_ENTRY;
  body     :record end;
 end;

function  is_near_valid(vaddr,body:Pointer):Boolean;
function  is_mask_valid(vaddr,body:Pointer;mask:DWORD):Boolean;

function  p_alloc  (vaddr:Pointer;size:Integer):p_stub_chunk;
function  p_alloc_m(vaddr:Pointer;size:Integer;mask:DWORD):p_stub_chunk;
procedure p_free   (chunk:p_stub_chunk);
procedure p_inc_ref(chunk:p_stub_chunk);
procedure p_dec_ref(chunk:p_stub_chunk);

implementation

uses
 {$IFDEF chunk_alloc}
 hamt,
 {$ENDIF}
 kern_rwlock,
 vm,
 vmparam,
 vm_map,
 vm_mmap,
 sys_vm_object;

var
 {$IFDEF chunk_alloc}
 chunk_alloc:TSTUB_HAMT64;
 {$ENDIF}

 chunk_free :TAILQ_HEAD=(tqh_first:nil;tqh_last:@chunk_free.tqh_first);

 chunk_lock :Pointer=nil;

function AlignUp(addr:PtrUInt;alignment:PtrUInt):PtrUInt; inline;
var
 tmp:PtrUInt;
begin
 if (alignment=0) then Exit(addr);
 tmp:=addr+PtrUInt(alignment-1);
 Result:=tmp-(tmp mod alignment)
end;

function is_near_valid(vaddr,body:Pointer):Boolean;
var
 delta:Int64;
begin
 delta:=abs(Int64(body)-Int64(vaddr));
 Result:=(delta<High(Integer));
end;

const
 XMASK:array[0..1] of DWORD=(
  $FF000000, //0xNN XX XX XX  4-byte instruction overlap
  $FFFF0000  //0xNN NN XX XX  3-byte instruction overlap
 );

function is_mask_valid(vaddr,body:Pointer;mask:DWORD):Boolean;
var
 delta:Int64;
 x:DWORD;
begin
 delta:=Int64(body)-Int64(vaddr);
 if not (abs(delta)<High(Integer)) then Exit(False);
 X:=XMASK[mask and 1];
 Result:=(DWORD(delta) and X)=(DWORD(mask) and X);
end;

function alloc_segment(start,size:QWORD):p_stub_chunk;
var
 map:vm_map_t;
 err:Integer;
begin
 Result:=nil;

 size:=AlignUp(size+SizeOf(stub_chunk),PAGE_SIZE);

 map:=@g_vmspace.vm_map;

 if (start=0) then
 begin
  start:=SCE_REPLAY_EXEC_START;
 end;

 err:=vm_mmap2(map,
               @start,
               size,
               VM_PROT_RWX,
               VM_PROT_RWX,
               MAP_ANON or MAP_PRIVATE,
               OBJT_DEFAULT,
               nil,
               0);

 if (err<>0) then Exit;

 vm_map_lock(map);
 vm_map_set_name_locked(map,start,start+size,'#patch',VM_INHERIT_PATCH);
 vm_map_unlock(map);

 Result:=Pointer(start);

 Result^.head         :=m_header;
 Result^.flags        :=m_free__chunk or m_first_chunk or m_last__chunk;
 Result^.prev_size    :=0;
 Result^.curr_size    :=size;
 Result^.refs         :=0;
 Result^.link.tqe_next:=nil;
 Result^.link.tqe_prev:=nil;
end;

procedure free_segment(chunk:p_stub_chunk);
var
 map:vm_map_t;
begin
 map:=@g_vmspace.vm_map;

 vm_map_lock  (map);
 vm_map_delete(map, qword(chunk), qword(chunk) + chunk^.curr_size);
 vm_map_unlock(map);
end;

procedure fix_next_size(chunk:p_stub_chunk);
var
 next:p_stub_chunk;
begin
 if ((chunk^.flags and m_last__chunk)=0) then
 begin
  next:=Pointer(chunk)+chunk^.curr_size;
  next^.prev_size:=chunk^.curr_size;
 end;
end;

procedure split_chunk(chunk:p_stub_chunk;used_size:Integer);
var
 chunk_size:Integer;
 next:p_stub_chunk;
begin
 chunk_size:=chunk^.curr_size;

 if (AlignUp(used_size+SizeOf(stub_chunk)*2,SizeOf(Pointer))>chunk_size) then Exit;

 used_size:=AlignUp(used_size+SizeOf(stub_chunk),SizeOf(Pointer));

 next:=Pointer(chunk)+used_size;

 chunk^.curr_size:=used_size;

 next^.head         :=m_header;
 next^.flags        :=m_free__chunk;
 next^.prev_size    :=used_size;
 next^.curr_size    :=chunk_size-used_size;
 next^.refs         :=0;
 next^.link.tqe_next:=nil;
 next^.link.tqe_prev:=nil;

 if ((chunk^.flags and m_last__chunk)<>0) then
 begin
  chunk^.flags:=chunk^.flags and (not m_last__chunk);
  next^.flags:=next^.flags or m_last__chunk;
 end;

 TAILQ_INSERT_TAIL(@chunk_free,next,@next^.link);

 fix_next_size(next);
end;

procedure merge_chunk(var chunk:p_stub_chunk);
var
 prev,next:p_stub_chunk;
begin

 if (chunk^.prev_size<>0) and
    ((chunk^.flags and m_first_chunk)=0) then
 begin
  prev:=Pointer(chunk)-chunk^.prev_size;
  if ((prev^.flags and m_free__chunk)<>0) then
  begin
   Assert(prev^.curr_size=chunk^.prev_size,'invalid prev chunk curr_size');
   Assert(prev^.refs=0                    ,'invalid prev chunk refs');

   TAILQ_REMOVE(@chunk_free,prev,@prev^.link);
   prev^.link:=Default(TAILQ_ENTRY);

   prev^.curr_size:=prev^.curr_size+chunk^.curr_size;

   if ((chunk^.flags and m_last__chunk)<>0) then
   begin
    prev^.flags:=prev^.flags or m_last__chunk;
   end;

   chunk^:=Default(stub_chunk);
   chunk:=prev;

   fix_next_size(chunk);
  end;
 end;

 if ((chunk^.flags and m_last__chunk)=0) then
 begin
  next:=Pointer(chunk)+chunk^.curr_size;
  if ((next^.flags and m_free__chunk)<>0) then
  begin
   Assert(next^.prev_size=chunk^.curr_size,'invalid next chunk prev_size');
   Assert(next^.refs=0                    ,'invalid next chunk refs');

   TAILQ_REMOVE(@chunk_free,next,@next^.link);
   next^.link:=Default(TAILQ_ENTRY);

   chunk^.curr_size:=chunk^.curr_size+next^.curr_size;

   if ((next^.flags and m_last__chunk)<>0) then
   begin
    chunk^.flags:=chunk^.flags or m_last__chunk;
   end;

   next^:=Default(stub_chunk);

   fix_next_size(chunk);
  end;
 end;
end;

function find_free_chunk(vaddr:Pointer;size:Integer):p_stub_chunk;
var
 entry,next:p_stub_chunk;
begin
 Result:=nil;
 size:=size+SizeOf(stub_chunk);
 entry:=TAILQ_FIRST(@chunk_free);

 while (entry<>nil) do
 begin
  next:=TAILQ_NEXT(entry,@entry^.link);
  //
  if (entry^.curr_size>=size) then
  begin
   if (vaddr=nil) or is_near_valid(vaddr,@entry^.body) then
   begin
    TAILQ_REMOVE(@chunk_free,entry,@entry^.link);
    entry^.link:=Default(TAILQ_ENTRY);
    Exit(entry);
   end;
  end;
  //
  entry:=next;
 end;
end;

function find_free_chunk_m(vaddr:Pointer;size:Integer;mask:DWORD):p_stub_chunk;
var
 entry,next:p_stub_chunk;
begin
 Result:=nil;
 size:=size+SizeOf(stub_chunk);
 entry:=TAILQ_FIRST(@chunk_free);

 while (entry<>nil) do
 begin
  next:=TAILQ_NEXT(entry,@entry^.link);
  //
  if (entry^.curr_size>=size) then
  begin
   if is_mask_valid(vaddr,@entry^.body,mask) then
   begin
    TAILQ_REMOVE(@chunk_free,entry,@entry^.link);
    entry^.link:=Default(TAILQ_ENTRY);
    Exit(entry);
   end;
  end;
  //
  entry:=next;
 end;
end;

function p_alloc(vaddr:Pointer;size:Integer):p_stub_chunk;
var
 chunk:p_stub_chunk;
begin
 rw_wlock(chunk_lock);

 chunk:=find_free_chunk(vaddr,size);

 if (chunk=nil) then
 begin
  chunk:=alloc_segment(QWORD(vaddr),size);
  Assert(chunk<>nil,'p_alloc NOMEM');

  if (vaddr<>nil) then
  if (not is_near_valid(vaddr,@chunk^.body)) then
  if (QWORD(vaddr)>High(Integer)) then
  begin
   free_segment(chunk);
   chunk:=alloc_segment(AlignUp(QWORD(vaddr)-High(Integer),PAGE_SIZE),size);
   Assert(chunk<>nil,'p_alloc NOMEM');
  end;

  if (vaddr<>nil) then
  begin
   Assert(is_near_valid(vaddr,@chunk^.body),'p_alloc is_near_valid');
  end;
 end;

 split_chunk(chunk,size);

 chunk^.flags:=chunk^.flags and (not m_free__chunk);

 {$IFDEF chunk_alloc}
 HAMT_insert64(@chunk_alloc,QWORD(chunk),chunk);
 {$ENDIF}

 rw_wunlock(chunk_lock);

 Result:=chunk;
end;

//

function p_alloc_m(vaddr:Pointer;size:Integer;mask:DWORD):p_stub_chunk;
var
 chunk:p_stub_chunk;
 x:Integer;
begin
 rw_wlock(chunk_lock);

 chunk:=find_free_chunk_m(vaddr,size,mask);

 if (chunk=nil) then
 begin
  x:=Integer(mask and XMASK[mask and 1]);

  if (x<0) and (QWORD(vaddr)<abs(x)) then
  begin
   Result:=nil;
   rw_wunlock(chunk_lock);
  end;

  chunk:=alloc_segment(QWORD(Int64(vaddr)+x),size);
  if (chunk=nil) then
  begin
   Result:=nil;
   rw_wunlock(chunk_lock);
  end;

  if not is_mask_valid(vaddr,@chunk^.body,mask) then
  begin
   free_segment(chunk);
   Result:=nil;
   rw_wunlock(chunk_lock);
  end;
 end;

 split_chunk(chunk,size);

 chunk^.flags:=chunk^.flags and (not m_free__chunk);

 {$IFDEF chunk_alloc}
 HAMT_insert64(@chunk_alloc,QWORD(chunk),chunk);
 {$ENDIF}

 rw_wunlock(chunk_lock);

 Result:=chunk;
end;

//

procedure p_free(chunk:p_stub_chunk);
begin
 if (chunk=nil) then Exit;

 rw_wlock(chunk_lock);

 {$IFDEF chunk_alloc}
 if (HAMT_search64(@chunk_alloc,QWORD(chunk))=nil) then
 begin
  rw_wunlock(chunk_lock);
  Exit;
 end;

 HAMT_delete64(@chunk_alloc,QWORD(chunk),nil);

 {$ENDIF}

 chunk^.flags:=chunk^.flags or m_free__chunk;

 merge_chunk(chunk);

 if ((chunk^.flags and (m_first_chunk or m_last__chunk))=(m_first_chunk or m_last__chunk)) then
 begin
  free_segment(chunk);
 end else
 begin
  TAILQ_INSERT_TAIL(@chunk_free,chunk,@chunk^.link);
 end;

 rw_wunlock(chunk_lock);
end;

procedure p_inc_ref(chunk:p_stub_chunk);
begin
 if (chunk=nil) then Exit;

 System.InterlockedIncrement(chunk^.refs);
end;

procedure p_dec_ref(chunk:p_stub_chunk);
begin
 if (chunk=nil) then Exit;

 if (System.InterlockedDecrement(chunk^.refs)=0) then
 begin
  p_free(chunk);
 end;
end;

end.

