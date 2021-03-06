with Ada.Streams;
with System;
with Interfaces.C;

with Reliable_Udp;
with Base_Udp;

with Buffers.Local;
--  with Buffers.Shared.Produce;
--  with Buffers.Shared.Consume;
with Log4ada.Loggers;

package Buffer_Handling is


   type Buffer_Handler_Obj is limited private;
   type Buffer_Handler_Obj_Access is access Buffer_Handler_Obj;

   --  DBG
   procedure Get_Filled_Buf (Obj : Buffer_Handler_Obj_Access);

   package Packet_Buffers is new
      Buffers.Generic_Buffers
         (Element_Type => Base_Udp.Packet_Stream);

   --  Index Type for "Handlers" array
   --  "is mod type" enables a circular parsing
   type Handle_Index_Type is mod Base_Udp.PMH_Buf_Nb;

   --  State of Buffer:
   --  Empty =>  Buf is released
   --  Near_Full => Buf is waiting for acks
   --  Full => Ready to be Released
   type State_Enum_Type is (Empty, Near_Full, Full);

   type Handler_Type is limited
      record
         Handle            : Buffers.Buffer_Handle_Type;
         State             : State_Enum_Type := Empty;
      end record;

   --  Contains all the Handlers
   type Handle_Array_Type is array (Handle_Index_Type) of Handler_Type;

   type Buffer_Handler_Type is
      record
         Handlers          : Handle_Array_Type;
         First             : Handle_Index_Type;
         Current           : Handle_Index_Type;
      end record;

   procedure Perror (Message : String);
   pragma Import (C, Perror, "perror");

   function mlockall (Flags : Interfaces.C.int)
      return Interfaces.C.int;
   pragma Import (C, mlockall, "mlockall");

   function mlock (Addr : System.Address;
                   Len  : Interfaces.C.size_t)
      return Interfaces.C.int;
   pragma Import (C, mlock, "mlock");

   --  Initialize "PMH_Buf_Nb" of Buffer and attach a buffer
   --  to each Handler of Handle_Array
   procedure Init_Buffers (Obj         : Buffer_Handler_Obj_Access;
                           --  Buffer_Name : String;
                           --  End_Point   : String;
                           Logger      : Log4ada.Loggers.Logger_Access);

   --  Stop Production and Consumption Message_Handling
   procedure Finalize_Buffers (Obj  : Buffer_Handler_Obj_Access);

   --  Release Buffer at Handlers (Index) and change its State to Empty
   procedure Release_Free_Buffer_At (Obj     : Buffer_Handler_Obj_Access;
                                     Index   : in Handle_Index_Type);


   --  Search position of ack received in current and previous buffers
   --  and then store content inside.
   function Search_Empty_Mark (Obj           : Buffer_Handler_Obj_Access;
                               First, Last   : Handle_Index_Type;
                               Data          : Base_Udp.Packet_Stream;
                               Seq_Nb        : Reliable_Udp.Packet_Number_Type) return Boolean;

   procedure Save_Ack (Obj             : Buffer_Handler_Obj_Access;
                       Seq_Nb          : in Reliable_Udp.Packet_Number_Type;
                       Packet_Number   : in Reliable_Udp.Packet_Number_Type;
                       Data            : in Base_Udp.Packet_Stream);

   --  Move Data Received to good location (Nb_Missed Offset) if packets
   --  were dropped
   procedure Copy_To_Correct_Location
                            (I, Nb_Missed    : Interfaces.Unsigned_64;
                             Data            : Base_Udp.Packet_Stream;
                             Data_Addr       : System.Address);

   --  Write 16#DEAD_BEEF# at missed packets location.
   --  Enables Search_Empty_Mark to save ack in correct Cell
   procedure Mark_Empty_Cell (I              :  Interfaces.Unsigned_64;
                              Data_Addr      :  System.Address;
                              Last_Addr      :  System.Address;
                              Nb_Missed      :  Interfaces.Unsigned_64);

   function New_Dest_Buffer (Obj             : Buffer_Handler_Obj_Access;
                             Dest_Buffer     : Buffers.Buffer_Produce_Access;
                             Size            : Interfaces.Unsigned_32;
                             Buffer_Size     : in out Interfaces.Unsigned_32;
                             Src_Index       : in out Interfaces.Unsigned_64;
                             Src_Handle      : in out Buffers.Buffer_Handle_Access;
                             Dest_Index      : in out Ada.Streams.Stream_Element_Offset;
                             Dest_Handle     : in out Buffers.Buffer_Handle_Access;
                             Src_Data_Stream : Base_Udp.Sequence_Type) return Boolean;

   --  Src_Handle get a new Src_Buffer if it's necessary returns 1 otherwise 0
   function New_Src_Buffer (Obj              : Buffer_Handler_Obj_Access;
                            Src_Index        : in out Interfaces.Unsigned_64;
                            Src_Handle       : in out Buffers.Buffer_Handle_Access;
                            Src_Data_Stream  : Base_Udp.Sequence_Type) return Boolean;

   procedure New_Src_Buffer (Obj              : Buffer_Handler_Obj_Access;
                             Src_Index       : in out Interfaces.Unsigned_64;
                             Src_Handle      : in out Buffers.Buffer_Handle_Access;
                             Src_Data_Stream : Base_Udp.Sequence_Type);

   procedure Copy_Packet_Data_To_Dest
                           (Obj              : Buffer_Handler_Obj_Access;
                            Buffer_Size      : Interfaces.Unsigned_32;
                            Src_Index        : in out Interfaces.Unsigned_64;
                            Src_Handle       : in out Buffers.Buffer_Handle_Access;
                            Dest_Handle      : Buffers.Buffer_Handle_Access;
                            Dest_Index       : in out Ada.Streams.Stream_Element_Offset;
                            Src_Data_Stream  : Base_Udp.Sequence_Type);

   --  Release Buffer and Reuse Handler only if Buffer State is "Full"
   task type Release_Full_Buf_Task is
      entry Start (Buffer_H   : Buffer_Handler_Obj_Access);
   end Release_Full_Buf_Task;

   --  Get the address of a New Buffer
   task type PMH_Buffer_Addr_Task is
      entry Start (Buffer_H   : Buffer_Handler_Obj_Access);
      entry New_Buffer_Addr (Buffer_Ptr : in out System.Address);
   end PMH_Buffer_Addr_Task;

   --  Change Buffer State from "Near_Full" to "Full" only if it contains
   --  all Packets
   task type Check_Buf_Integrity_Task is
      entry Start (Buffer_H   : Buffer_Handler_Obj_Access);
      entry Stop;
   end Check_Buf_Integrity_Task;

   task type Handle_Data_Task is
      entry Start (Buffer_H   : Buffer_Handler_Obj_Access;
                   Buffer_Set : Buffers.Buffer_Produce_Access;
                   Logger     : Log4ada.Loggers.Logger_Access);
   end Handle_Data_Task;

private

   type Buffer_Handler_Obj is limited
      record
         Buffer_Handler    : Buffer_Handler_Type;
         --  Consumption   : Buffers.Shared.Consume.Consume_Couple_Type;
         --  Production    : Buffers.Shared.Produce.Produce_Couple_Type;

         Buffer            : Buffers.Local.Local_Buffer_Type;
      end record;

end Buffer_Handling;
