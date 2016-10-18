with Ada.Unchecked_Deallocation;
with Ada.Unchecked_Conversion;
with Ada.Streams;
with GNAT.Sockets;
with Interfaces;
with Interfaces.C;

with Buffers;

with Reliable_Udp;
with Base_Udp;

package Data_Transport.Udp_Socket_Server is

   type Socket_Server_Access is access all Socket_Server_Task;

   --  Used to contain the data of a packet already sent in case of drops
   --  Is_Buffer_Size equal True if the Stream Data contains the size of the buffer sent.
   type History_Type is
      record
         Data           : Base_Udp.Packet_Stream;
         Is_Buffer_Size : Boolean := False;
      end record;

   --  Main Task
   task type Socket_Server_Task (Buffer_Set : Buffers.Buffer_Consume_Access)
         is new Transport_Layer_Interface with
      entry Initialise (Network_Interface : String;
                        Port : GNAT.Sockets.Port_Type);
      overriding entry Connect;
      overriding entry Disconnect;
   end Socket_Server_Task;

   procedure Free is new Ada.Unchecked_Deallocation (Socket_Server_Task,
                                                     Socket_Server_Access);

   procedure Send_Buffer_Data (Buffer_Set    : Buffers.Buffer_Consume_Access;
                               Packet_Number : in out Reliable_Udp.Pkt_Nb);

   --  Gets all the content of a buffer as a stream,
   --  divides it into packets and sends them to consumer.
   procedure Send_All_Stream (Payload        : Ada.Streams.Stream_Element_Array;
                              Packet_Number  : in out Reliable_Udp.Pkt_Nb);

   --  Sends a packet to consumer,
   --  if Is_Buffer_Size is true the packet sent's length will only be 6 Bytes
   --  (Header + Size as u_int32)
   procedure Send_Packet (Payload            : Base_Udp.Packet_Stream;
                          Is_Buffer_Size     : Boolean := False);

   procedure Rcv_Ack;

   --  Sends messages to producer, wait for its reply
   --  with the same message to start acquisition
   procedure Server_HandShake;

   function To_Int is
      new Ada.Unchecked_Conversion (GNAT.Sockets.Socket_Type,
         Interfaces.C.int);

end Data_Transport.Udp_Socket_Server;
