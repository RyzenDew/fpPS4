unit seh64;

{$mode objfpc}{$H+}

interface

implementation

uses
  Windows,
  ntapi,
  SysConst,
  SysUtils,
  hamt,
  ps4libdoc,
  sys_types,
  sys_kernel,
  ps4_program;

function AddVectoredExceptionHandler(FirstHandler: DWORD; VectoredHandler: pointer): pointer; stdcall;
  external 'kernel32.dll' name 'AddVectoredExceptionHandler';
function RemoveVectoredExceptionHandler(VectoredHandlerHandle: pointer): ULONG; stdcall;
  external 'kernel32.dll' name 'RemoveVectoredExceptionHandler';  
function GetModuleHandleEx(dwFlags: DWORD; lpModuleName: pointer; var hModule: THandle): BOOL; stdcall;
  external 'kernel32.dll' name 'GetModuleHandleExA';

// sysutils.GetModuleName();

const
  GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 2;
  GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS       = 4;

function GetModuleByAdr(adr:Pointer):THandle;
var
 Flags:DWORD;
begin
 Flags:=GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS or GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
 Result:=0;
 GetModuleHandleEx(Flags,adr,Result);
end;

function RunErrorCode(const rec: TExceptionRecord): longint;
begin
  { negative result means 'FPU reset required' }
  case rec.ExceptionCode of
    STATUS_INTEGER_DIVIDE_BY_ZERO:      result := 200;    { reDivByZero }
    STATUS_FLOAT_DIVIDE_BY_ZERO:        result := -208;   { !!reZeroDivide }
    STATUS_ARRAY_BOUNDS_EXCEEDED:       result := 201;    { reRangeError }
    STATUS_STACK_OVERFLOW:              result := 202;    { reStackOverflow }
    STATUS_FLOAT_OVERFLOW:              result := -205;   { reOverflow }
    STATUS_FLOAT_DENORMAL_OPERAND,
    STATUS_FLOAT_UNDERFLOW:             result := -206;   { reUnderflow }
    STATUS_FLOAT_INEXACT_RESULT,
    STATUS_FLOAT_INVALID_OPERATION,
    STATUS_FLOAT_STACK_CHECK:           result := -207;   { reInvalidOp }
    STATUS_INTEGER_OVERFLOW:            result := 215;    { reIntOverflow }
    STATUS_ILLEGAL_INSTRUCTION:         result := -216;
    STATUS_ACCESS_VIOLATION:            result := 216;    { reAccessViolation }
    STATUS_CONTROL_C_EXIT:              result := 217;    { reControlBreak }
    STATUS_PRIVILEGED_INSTRUCTION:      result := 218;    { rePrivilegedInstruction }
    STATUS_FLOAT_MULTIPLE_TRAPS,
    STATUS_FLOAT_MULTIPLE_FAULTS:       result := -255;   { indicate FPU reset }
  else
    result := 255;                                        { reExternalException }
  end;
end;

procedure TranslateMxcsr(mxcsr: longword; var code: longint);
begin
  { we can return only one value, further one's are lost }
  { InvalidOp }
  if (mxcsr and 1)<>0 then
    code:=-207
  { Denormal }
  else if (mxcsr and 2)<>0 then
    code:=-206
  { !!reZeroDivide }
  else if (mxcsr and 4)<>0 then
    code:=-208
  { reOverflow }
  else if (mxcsr and 8)<>0 then
    code:=-205
  { Underflow }
  else if (mxcsr and 16)<>0 then
    code:=-206
  { Precision }
  else if (mxcsr and 32)<>0 then
    code:=-207
  else { this should not happen }
    code:=-255
end;


function RunErrorCodex64(const rec: TExceptionRecord; const context: TContext): Longint;
begin
 Result:=RunErrorCode(rec);
 if (Result=-255) then
   TranslateMxcsr(context.MxCsr,result);
end;

type
 _TElf_node=class(TElf_node)
 end;

 PTLQRec=^TLQRec;
 TLQRec=record
  pAddr:Pointer;
  ExceptAddr:Pointer;
  LastAdr:Pointer;
  LastNid:QWORD;
 end;

procedure trav_proc(data,userdata:Pointer);
var
 adr:Pointer;
 nid:QWORD;
begin
 if (data=nil) then Exit;
 safe_move_ptr(PPointer(data)[0],adr);
 safe_move_ptr(PPointer(data)[1],nid);
 if (adr>=PTLQRec(userdata)^.pAddr) then
 if (adr<=PTLQRec(userdata)^.ExceptAddr) then
 if (adr>PTLQRec(userdata)^.LastAdr) then
 begin
  PTLQRec(userdata)^.LastAdr:=adr;
  PTLQRec(userdata)^.LastNid:=nid;
 end;
end;

function IsSubTrie64(n:PHAMTNode64):Boolean; inline;
var
 BaseValue:PtrUint;
begin
 safe_move_ptr(n^.BaseValue,BaseValue);
 Result:=(BaseValue and 1)<>0;
end;

function GetBitMapSize64(n:PHAMTNode64):QWORD; inline;
var
 BitMapKey:QWORD;
begin
 safe_move_ptr(n^.BitMapKey,BitMapKey);
 Result:=PopCnt(BitMapKey);
 Result:=Result and HAMT64.node_mask;
 if (Result=0) then Result:=HAMT64.node_size;
end;

function GetSubTrie64(n:PHAMTNode64):PHAMTNode64; inline;
var
 BaseValue:PtrUint;
begin
 safe_move_ptr(n^.BaseValue,BaseValue);
 PtrUint(Result):=(BaseValue or 1) xor 1;
end;

function GetValue64(n:PHAMTNode64):Pointer; inline;
begin
 safe_move_ptr(n^.BaseValue,Result);
end;

procedure HAMT_traverse_trie64(node:PHAMTNode64;cb:Tfree_data_cb;userdata:Pointer); inline;
type
 PStackNode=^TStackNode;
 TStackNode=packed record
  cnode,enode:PHAMTNode64;
 end;
var
 curr:PStackNode;
 data:array[0..HAMT64.stack_max] of TStackNode;
 Size:QWORD;
begin
 if IsSubTrie64(node) then
 begin
  curr:=@data;
  Size:=GetBitMapSize64(node);
  With curr^ do
  begin
   cnode:=GetSubTrie64(node);
   enode:=@cnode[Size];
  end;
  repeat
   if (curr^.cnode>=curr^.enode) then
   begin
    if (curr=@data) then Break;
    Dec(curr);
    Inc(curr^.cnode);
    Continue;
   end;
   if IsSubTrie64(curr^.cnode) then
   begin
    node:=curr^.cnode;
    Inc(curr);
    Size:=GetBitMapSize64(node);
    With curr^ do
    begin
     cnode:=GetSubTrie64(node);
     enode:=@cnode[Size];
    end;
   end else
   begin
    if (cb<>nil) then
     cb(GetValue64(curr^.cnode),userdata);
    Inc(curr^.cnode);
   end;
  until false;
 end else
 begin
  if (cb<>nil) then
   cb(GetValue64(node),userdata);
 end;
end;

function HAMT_traverse64(hamt:THAMT;cb:Tfree_data_cb;userdata:Pointer):Boolean;
var
 i:Integer;
 node:PHAMTNode64;
begin
 if (hamt=nil) then Exit(False);
 For i:=0 to HAMT64.root_mask do
 begin
  node:=@PHAMTNode64(hamt)[i];
  HAMT_traverse_trie64(node,cb,userdata);
 end;
 Result:=True;
end;

Function FindLQProc(node:TElf_node;r:PTLQRec):Boolean;
var
 i,l:SizeInt;
 lib:PLIBRARY;
 MapSymbol:THAMT;
 Import:Boolean;
begin
 Result:=false;
 l:=Length(_TElf_node(node).aLibs);
 if (l<>0) then
 begin
  r^.LastAdr:=nil;
  r^.LastNid:=0;
  For i:=0 to l-1 do
  begin
   safe_move_ptr(_TElf_node(node).aLibs[i],lib);
   if (lib<>nil) then
   begin
    Import:=True;
    safe_move(lib^.Import,Import,SizeOf(Boolean));
    if not Import then
    begin
     safe_move_ptr(lib^.MapSymbol,MapSymbol);
     HAMT_traverse64(MapSymbol,@trav_proc,r);
    end;
   end;
  end;
  Result:=(r^.LastAdr<>nil);
 end;
end;

Function FindLQProcStr(node:TElf_node;r:PTLQRec):shortstring;
var
 adr:Pointer;
begin
 Result:='';
 if FindLQProc(node,r) then
 begin
  Result:=ps4libdoc.GetFunctName(r^.LastNid);
 end else
 begin
  adr:=node.GetdInit;

  if (adr>=r^.pAddr) then
  if (adr<=r^.ExceptAddr) then
  if (adr>r^.LastAdr) then
  begin
   r^.LastAdr:=adr;
   Result:='dtInit';
  end;

  adr:=node.GetdFini;

  if (adr>=r^.pAddr) then
  if (adr<=r^.ExceptAddr) then
  if (adr>r^.LastAdr) then
  begin
   r^.LastAdr:=adr;
   Result:='dtFini';
  end;

  adr:=node.GetEntry;

  if (adr>=r^.pAddr) then
  if (adr<=r^.ExceptAddr) then
  if (adr>r^.LastAdr) then
  begin
   r^.LastAdr:=adr;
   Result:='Entry';
  end;

 end;

end;

Procedure WriteErr(Const s:shortstring);
var
 num:DWORD;
begin
 WriteConsole(GetStdHandle(STD_ERROR_HANDLE),@s[1],ord(s[0]),num,nil);
end;

function IntToStr(Value:longint): shortstring;
begin
 System.Str(Value,result);
end;

function GetModuleName(Module:HMODULE): shortstring;
var
 Len:DWORD;
 Buffer:array[0..MAX_PATH] of WideChar;
 P:PWideChar;
begin
 Len:=GetModuleFileNameW(Module,@Buffer,MAX_PATH);
 P:=@Buffer[Len];
 While (P<>@Buffer) do
 begin
  if (P^='\') then
  begin
   Inc(P);
   Break;
  end;
  Dec(P);
 end;
 Len:=@Buffer[Len]-P;
 Len:=UnicodeToUtf8(@Result[1],255,P,Len);
 Byte(Result[0]):=Len;
end;

Procedure DumpException(node:TElf_node;code:Longint;ExceptAddr:Pointer;ContextRecord:PCONTEXT);
var
 Report:shortstring;
 pFileName:PChar;
 Mem:TMemChunk;
 top,rbp:PPointer;

 procedure print_adr;
 var
  r:TLQRec;
  n:shortstring;
 begin
  Report:='  $'+hexstr(ExceptAddr);
  if (node<>nil) then
  begin
   Mem:=node.GetCodeFrame;
   if (Mem.pAddr<>nil) and (Mem.nSize<>0) then
   begin
    safe_move_ptr(node.pFileName,pFileName);
    Report:=Report+' offset $'+hexstr(ExceptAddr-Mem.pAddr,8)+' '+safe_str(pFileName);

    r.pAddr:=Mem.pAddr;
    r.ExceptAddr:=ExceptAddr;

    n:=FindLQProcStr(node,@r);

    Report:=Report+':'+n+'+$'+hexstr(ExceptAddr-r.LastAdr,8);
   end;
  end;
  Report:=Report+#13#10;
  WriteErr(Report);
 end;

 procedure print_adr2;
 begin
  Report:='  $'+hexstr(ExceptAddr);
  Report:=Report+' '+GetModuleName(GetModuleByAdr(ExceptAddr));
  Report:=Report+#13#10;
  WriteErr(Report);
 end;

begin
 Report:='';
 Report:=Report+'Message: '+SysConst.GetRunError(abs(code));
 Report:=Report+' ('+IntToStr(longint(code))+')';
 Report:=Report+#13#10;
 WriteErr(Report);
 print_adr;
 if (node<>nil) then node.Release;
 top:=Pointer(ContextRecord^.Rbp);
 //if (top>StackBottom) and (top<StackTop) then
 begin
  rbp:=top;
  repeat
   safe_move_ptr(rbp[1],ExceptAddr);
   safe_move_ptr(rbp[0],rbp);
   if (ExceptAddr<>nil) then
   begin
    node:=ps4_app.AcqureFileByCodeAdr(ExceptAddr);
    if (node<>nil) then
    begin
     print_adr;
     node.Release;
    end else
    begin
     print_adr2;
    end;
   end;
  until (node=nil) {or (rbp>top) or (rbp<StackBottom)};
 end;
end;

const
 FPC_EXCEPTION_CODE=$E0465043;

{
psllq = _m128i _mm_slli_epi64(_m128i a, int cnt)
psrlq = _m128i _mm_srli_epi64(_m128i a, int cnt)

SSP_FORCEINLINE __m128i ssp_logical_bitwise_select_SSE2	(__m128i a,b,mask)

{
    a = _mm_and_si128   ( a,    mask ); // clear a where mask = 0
    b = _mm_andnot_si128( mask, b    ); // clear b where mask = 1
    a = _mm_or_si128    ( a,    b    ); // a = a OR b
    return a;
}

SSP_FORCEINLINE __m128i ssp_inserti_si64_SSE2( __m128i a, __m128i b, int len, int ndx )

    const static __m128i MASK = SSP_CONST_SET_32I( 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF );

    int left = ndx + len;
    __m128i m;
    m = _mm_slli_epi64( MASK, 64-left );    // clear the mask to the left
    m = _mm_srli_epi64( m,    64-len  );    // clear the mask to the right
    m = _mm_slli_epi64( m,    ndx     );    // put the mask into the proper position
    b = _mm_slli_epi64( b,    ndx     );    // put the insert bits into the proper position

    a = ssp_logical_bitwise_select_SSE2( b, a, m );
    return a;
}

//f2      0f 78 [c1] [30] [00] insertq $0x0,$0x30,%xmm1 ,%xmm0  c1 = [11] %xmm[000]   %xmm[001]
//f2 [44] 0f 78 [c7] [30] [00] insertq $0x0,$0x30,%xmm7 ,%xmm8  c7 = [11] %xmm[000]+8 %xmm[111]
//f2 [41] 0f 78 [f8] [30] [00] insertq $0x0,$0x30,%xmm8 ,%xmm7  f8 = [11] %xmm[111]   %xmm[000]+8
//f2 [45] 0f 78 [c7] [30] [00] insertq $0x0,$0x30,%xmm15,%xmm8  c7 = [11] %xmm[000]+8 %xmm[111]+8

const
 IQ_MASK:array[0..3] of DWORD=($FFFFFFFF,$FFFFFFFF,$FFFFFFFF,$FFFFFFFF);

procedure ssp_logical_bitwise_select_SSE2; assembler; nostackframe;
asm
 andps  %xmm2, %xmm0 //( a,    mask ) r = %xmm0
 andnps %xmm1, %xmm2 //( mask, b    ) r = %xmm2
 orps   %xmm2, %xmm0 //( a,    b    ) r = %xmm0
end;

procedure insertq_xmm5_xmm8_30_00; assembler;
const
 len=$30;
 ndx=$00;
 left=ndx+len;
 m64_left=64-left;
 m64_len =64-len;
var
 xmm0,xmm1,xmm2:array[0..3] of DWORD;
asm
 Movq %xmm0,xmm0
 Movq %xmm1,xmm1
 Movq %xmm2,xmm2

 Movq IQ_MASK,%xmm2

 //a = xmm5
 //b = xmm8

 Movq  %xmm8,%xmm0
 Movq  %xmm5,%xmm1

 psllq m64_left,%xmm2 //m = ( MASK, 64-left ) clear the mask to the left
 psrlq m64_len ,%xmm2 //m = ( m,    64-len  ) clear the mask to the right
 psllq ndx     ,%xmm2 //m = ( m,    ndx     ) put the mask into the proper position
 psllq ndx     ,%xmm0 //b = ( b,    ndx     ) put the insert bits into the proper position

 call  ssp_logical_bitwise_select_SSE2

 Movq  %xmm0,%xmm5

 Movq xmm0,%xmm0
 Movq xmm1,%xmm1
 Movq xmm2,%xmm2
end;

procedure patch_insertq(p:Pbyte);
var
 i:int64;
begin
 Case p[1] of
  $0f:
   begin
    p[0]:=$90;
    p[1]:=$90;
    p[2]:=$90;
    p[3]:=$90;
    p[4]:=$90;
    p[5]:=$90;
   end;
  $41:
   begin
    //e8 [00 00 00 00] ,(90) callq rel32, nop
    p[0]:=$90;
    p[1]:=$90;
    p[2]:=$90;
    p[3]:=$90;
    p[4]:=$90;
    p[5]:=$90;
    p[6]:=$90;
   end;
  $44:
   begin
    p[0]:=$90;
    p[1]:=$90;
    p[2]:=$90;
    p[3]:=$90;
    p[4]:=$90;
    p[5]:=$90;
    p[6]:=$90;
   end;
  $45:
   begin
    p[0]:=$90;
    p[1]:=$90;
    p[2]:=$90;
    p[3]:=$90;
    p[4]:=$90;
    p[5]:=$90;
    p[6]:=$90;
   end;
  else;
 end;
end;

function Test_SIGILL(const rec:TExceptionRecord;ctx:PCONTEXT):longint;
begin
 case rec.ExceptionCode of
  STATUS_ILLEGAL_INSTRUCTION:
    begin
     Case PDWORD(rec.ExceptionAddress)[0] of  //4 byte
                 //00 11 22 33 44  55   66
      $780f41f2, //f2 41 0f 78 e8 [30] [00]           insertq $0x0,$0x30,%xmm8,%xmm5
      $780f44f2,
      $780f45f2:
       if ((PBYTE(rec.ExceptionAddress)[4] and $C0)=$C0) then
       begin
        patch_insertq(rec.ExceptionAddress);
        NtContinue(ctx,False);
       end;
      else;
     end;

     Case (PDWORD(rec.ExceptionAddress)[0] and $FFFFFF) of  //3 byte
                // 00 11 22   33   44   55               c1 = [11] %xmm[000] %xmm[001]
       $780FF2: //[f2 0f 78] [c1] [30] [00]              insertq $0x0,$0x30,%xmm1,%xmm0
       if ((PBYTE(rec.ExceptionAddress)[3] and $C0)=$C0) then
       begin
        patch_insertq(rec.ExceptionAddress);
        NtContinue(ctx,False);
       end;
      else;
     end;

     Writeln(StdErr,HexStr(PDWORD(rec.ExceptionAddress)[0],8)); //C1780FF2
     Exit(EXCEPTION_EXECUTE_HANDLER); //Unknow
    end;
  else
   Exit(EXCEPTION_CONTINUE_SEARCH); //Next
 end;
end;

function ProcessException(p: PExceptionPointers):longint; stdcall;
var
 code: Longint;
 node:TElf_node;
begin
 Result := 0;

 if (p^.ExceptionRecord^.ExceptionCode=FPC_EXCEPTION_CODE) then Exit(EXCEPTION_CONTINUE_SEARCH);

 if (Test_SIGILL(p^.ExceptionRecord^,p^.ContextRecord)=EXCEPTION_CONTINUE_EXECUTION) then Exit(EXCEPTION_CONTINUE_EXECUTION);

 //DumpException(nil,0,p^.ExceptionRecord^.ExceptionAddress,P^.ContextRecord);

 node:=ps4_app.AcqureFileByCodeAdr(p^.ExceptionRecord^.ExceptionAddress);
 if (node=nil) and
    (GetModuleByAdr(p^.ExceptionRecord^.ExceptionAddress)<>GetModuleByAdr(@ProcessException)) then
    Exit(EXCEPTION_CONTINUE_SEARCH);

 code:=RunErrorCodex64(p^.ExceptionRecord^,p^.ContextRecord^);
 DumpException(node,code,p^.ExceptionRecord^.ExceptionAddress,P^.ContextRecord);
 halt;
end;

var
  VEHandler: pointer = Nil;

procedure InstallExceptionHandler;
begin
  VEHandler := AddVectoredExceptionHandler(1, @ProcessException);
end;

procedure UninstallExceptionHandler;
begin
  if Assigned(VEHandler) then
  begin
    RemoveVectoredExceptionHandler(VEHandler);
    VEHandler := Nil;
  end;
end;

initialization
  InstallExceptionHandler;

finalization
  UninstallExceptionHandler;
end.
