@import Foundation;
@import MachO;

#import "launch-cache/dyld_cache_format.h"

unsigned long roundUpToPage(unsigned long address)
{
	return (address+0xfff)/0x1000*0x1000;
}

unsigned long readUleb(unsigned char** cursor)
{
	unsigned long value=0;
	unsigned long byte;
	int bit=0;
	
	do
	{
		byte=**cursor;
		value|=(byte&0x7f)<<bit;
		
		bit+=7;
		(*cursor)++;
	}
	while(byte&0x80);
	
	return value;
}

void writeUleb(unsigned char** cursor,unsigned long value)
{
	do
	{
		**cursor=value&0x7f;
		value=value>>7;
		
		if(value)
		{
			**cursor|=0x80;
		}
		
		(*cursor)++;
	}
	while(value);
}

char* cachePointerWithAddress(struct dyld_cache_header* cacheHeader,long address)
{
	assert(cacheHeader);
	
	struct dyld_cache_mapping_info* mappings=(struct dyld_cache_mapping_info*)((char*)cacheHeader+cacheHeader->mappingOffset);
	for(int index=0;index<cacheHeader->mappingCount;index++)
	{
		if(address>=mappings[index].address)
		{
			if(address<mappings[index].address+mappings[index].size)
			{
				return (char*)cacheHeader+address-mappings[index].address+mappings[index].fileOffset;
			}
		}
	}
	
	abort();
}

struct mach_header* imageHeaderWithPath(struct dyld_cache_header* cacheHeader,NSString* path)
{
	struct dyld_cache_image_info* cacheImages=(struct dyld_cache_image_info*)((char*)cacheHeader+cacheHeader->imagesOffset);
	for(int imageIndex=0;imageIndex<cacheHeader->imagesCount;imageIndex++)
	{
		if([@((char*)cacheHeader+cacheImages[imageIndex].pathFileOffset) isEqual:path])
		{
			return (struct mach_header*)cachePointerWithAddress(cacheHeader,cacheImages[imageIndex].address);
		}
	}
	
	abort();
}

NSMutableSet<NSNumber*>* getBindDataOffsets(unsigned char* stream,int size)
{
	NSMutableSet* set=NSMutableSet.alloc.init.autorelease;
	
	unsigned char* cursor=stream;
	int offset=0;
	
	while(cursor<stream+size)
	{
		unsigned char byte=*cursor;
		unsigned char immediate=byte&BIND_IMMEDIATE_MASK;
		cursor++;
		
		switch(byte&BIND_OPCODE_MASK)
		{
			case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
				NSLog(@"set dylib ordinal %d",immediate);
				break;
			
			case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
				NSLog(@"set symbol name %s flags %d",cursor,immediate);
				cursor+=strlen((char*)cursor)+1;
				break;
			
			case BIND_OPCODE_SET_TYPE_IMM:
				NSLog(@"set type %d",immediate);
				assert(immediate==1);
				break;
			
			case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
				offset=readUleb(&cursor);
				NSLog(@"set segment %d offset %x",immediate,offset);
				assert(immediate==1);
				break;
			
			case BIND_OPCODE_ADD_ADDR_ULEB:
			{
				unsigned long delta=readUleb(&cursor);
				NSLog(@"add address %lx",delta);
				offset+=delta;
				break;
			}
			
			case BIND_OPCODE_DO_BIND:
				NSLog(@"bind %x",offset);
				[set addObject:@(offset)];
				offset+=4;
				break;
			
			case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
				NSLog(@"bind %x adding %x pointers",offset,immediate);
				[set addObject:@(offset)];
				offset+=immediate*4+4;
				break;
			
			case BIND_OPCODE_DONE:
				
				// TODO: using this as a "nop" since type is always 1!
				// remove assert above when i do something about this too!!!
				
				*(cursor-1)=BIND_OPCODE_SET_TYPE_IMM|1;
				
				NSLog(@"done");
				break;
			
			default:
				abort();
		}
	}
	
	return set;
}

NSMutableArray<NSNumber*>* getRebaseAddresses(struct dyld_cache_header* cacheHeader)
{
	NSMutableArray<NSNumber*>* array=NSMutableArray.alloc.init.autorelease;
	
	struct dyld_cache_slide_info* info=(struct dyld_cache_slide_info*)((char*)cacheHeader+cacheHeader->slideInfoOffset);
	assert(info->version==1);
	
	unsigned short* toc=(unsigned short*)((char*)info+info->toc_offset);
	unsigned char* entries=(unsigned char*)info+info->entries_offset;
	
	int dataAddress=((struct dyld_cache_mapping_info*)((char*)cacheHeader+cacheHeader->mappingOffset))[1].address;
	
	for(int pageIndex=0;pageIndex<info->toc_count;pageIndex++)
	{
		unsigned char* entry=entries+toc[pageIndex]*info->entries_size;
		
		for(int byteIndex=0;byteIndex<info->entries_size;byteIndex++)
		{
			for(int bitIndex=0;bitIndex<8;bitIndex++)
			{
				if(entry[byteIndex]&(1<<bitIndex))
				{
					[array addObject:@(dataAddress+pageIndex*0x1000+byteIndex*0x20+bitIndex*4)];
				}
			}
		}
	}
	
	return array;
}

NSData* extract(struct dyld_cache_header* cacheHeader,NSString* imagePath)
{
	NSLog(@"search %@",imagePath);
	struct mach_header* inHeader=imageHeaderWithPath(cacheHeader,imagePath);
	
	NSMutableData* outData=[NSMutableData dataWithLength:0x1000000];
	
	// TODO: just hardcoded, and no flags
	
	struct mach_header* outHeader=(struct mach_header*)outData.bytes;
	outHeader->magic=MH_MAGIC;
	outHeader->cputype=0xc;
	outHeader->cpusubtype=0x9;
	outHeader->filetype=MH_DYLIB;
	
	char* outCursor=(char*)outHeader+inHeader->sizeofcmds;
	
	struct segment_command* outTextSegment=NULL;
	struct segment_command* outDataSegment=NULL;
	struct segment_command* outLinkeditSegment=NULL;
	struct section* outSelSection=NULL;
	
	struct load_command* outCommand=(struct load_command*)(outHeader+1);
	
	struct load_command* inCommand=(struct load_command*)(inHeader+1);
	for(int commandIndex=0;commandIndex<inHeader->ncmds;commandIndex++)
	{
		BOOL copied=false;
		
		switch(inCommand->cmd)
		{
			case LC_SEGMENT:
			{
				memcpy(outCommand,inCommand,inCommand->cmdsize);
				struct segment_command* outSegment=(struct segment_command*)outCommand;
				copied=true;
				
				NSLog(@"segment %s",outSegment->segname);
				
				int skipPrefix=0;
				int delta=0;
				
				if(!strcmp(outSegment->segname,SEG_TEXT))
				{
					skipPrefix=outCursor-(char*)outHeader;
					outTextSegment=outSegment;
				}
				else
				{
					delta=outCursor-(char*)outHeader-outSegment->fileoff;
				}
				
				outSegment->fileoff+=delta;
				
				struct section* outStubsSection=NULL;
				struct section* outSelRefSection=NULL;
				struct section* outObjcInfoSection=NULL;
					
				struct section* sections=(struct section*)(outSegment+1);
				for(int index=0;index<outSegment->nsects;index++)
				{
					int sectionDelta=sections[index].offset==0?0:delta;
					NSLog(@"section %s old offset %x new offset %x",sections[index].sectname,sections[index].offset,sections[index].offset+sectionDelta);
					sections[index].offset+=sectionDelta;
					
					if(!strncmp(sections[index].sectname,"__picsymbolstub4",16))
					{
						outStubsSection=&sections[index];
					}
					if(!strncmp(sections[index].sectname,"__objc_selrefs",16))
					{
						outSelRefSection=&sections[index];
					}
					if(!strncmp(sections[index].sectname,"__objc_methname",16))
					{
						outSelSection=&sections[index];
					}
					if(!strncmp(sections[index].sectname,"__objc_imageinfo",16))
					{
						outObjcInfoSection=&sections[index];
					}
				}
				
				if(!strcmp(outSegment->segname,SEG_DATA))
				{
					outDataSegment=outSegment;
				}
				
				if(!strcmp(outSegment->segname,SEG_LINKEDIT))
				{
					outLinkeditSegment=outSegment;
					break;
				}
				
				memcpy(outCursor,cachePointerWithAddress(cacheHeader,outSegment->vmaddr)+skipPrefix,outSegment->filesize-skipPrefix);
				outCursor+=outSegment->filesize;
				outCursor=(char*)outHeader+roundUpToPage(outCursor-(char*)outHeader);
				
				if(outStubsSection)
				{
					// TODO: super cursed, assumes the first is correct and they're in order.. fixes 4 in GL driver but may well break something else
					
					int first=0;
					
					int* lines=(int*)((char*)outHeader+outStubsSection->offset);
					for(int index=0;index<outStubsSection->size/16;index++)
					{
						int* line=&lines[index*4+3];
						
						if(first)
						{
							int guess=first-index*0xc;
							if(*line!=guess)
							{
								NSLog(@"reset stub data %x to %x",*line,guess);
								*line=guess;
							}
						}
						else
						{
							first=*line;
						}
					}
				}
				
				if(outSelRefSection)
				{
					// TODO: will not fix objc in general, only calling selectors, which is all GL driver does
					
					assert(outSelSection);
					char* sels=(char*)outHeader+outSelSection->offset;
					
					int* refs=(int*)((char*)outHeader+outSelRefSection->offset);
					for(int refIndex=0;refIndex<outSelRefSection->size/4;refIndex++)
					{
						char* sel=cachePointerWithAddress(cacheHeader,refs[refIndex]);
						
						int foundIndex=-1;
						for(int selIndex=0;selIndex<outSelSection->size;selIndex++)
						{
							if(!strcmp(sel,sels+selIndex))
							{
								foundIndex=selIndex;
								break;
							}
						}
						assert(foundIndex!=-1);
						
						refs[refIndex]=outSelSection->addr+foundIndex;
						
						NSLog(@"reset selector %s to %x",sel,refs[refIndex]);
					}
				}
				
				if(outObjcInfoSection)
				{
					int* info=(int*)((char*)outHeader+outObjcInfoSection->offset);
					NSLog(@"objc info %x %x",info[0],info[1]);
					info[1]=0;
				}
				
				break;
			}
			
			case LC_DYLD_INFO_ONLY:
			{
				struct dyld_info_command* inInfo=(struct dyld_info_command*)inCommand;
				memcpy(outCommand,inInfo,inInfo->cmdsize);
				struct dyld_info_command* outInfo=(struct dyld_info_command*)outCommand;
				copied=true;
				
				// TODO: the cursed squishing together, depends on binds parsing removing all done opcodes
				
				outInfo->bind_off=outCursor-(char*)outHeader;
				memcpy(outCursor,(char*)cacheHeader+inInfo->bind_off,inInfo->bind_size);
				outCursor+=inInfo->bind_size;
				
				memcpy(outCursor,(char*)cacheHeader+inInfo->lazy_bind_off,inInfo->lazy_bind_size);
				outCursor+=inInfo->lazy_bind_size;
				
				outInfo->bind_size=outCursor-(char*)outHeader-outInfo->bind_off;
				
				outInfo->lazy_bind_off=0;
				outInfo->lazy_bind_size=0;
				
				assert(outInfo->weak_bind_size==0);
				outInfo->weak_bind_off=0;
				
				outInfo->export_off=outCursor-(char*)outHeader;
				memcpy(outCursor,(char*)cacheHeader+inInfo->export_off,inInfo->export_size);
				outCursor+=inInfo->export_size;
				
				NSMutableSet<NSNumber*>* binds=getBindDataOffsets((unsigned char*)outHeader+outInfo->bind_off,outInfo->bind_size);
				
				outInfo->rebase_off=outCursor-(char*)outHeader;
				
				*outCursor=REBASE_OPCODE_SET_TYPE_IMM|REBASE_TYPE_POINTER;
				outCursor++;
				
				for(NSNumber* addressWrap in getRebaseAddresses(cacheHeader))
				{
					int address=addressWrap.intValue;
					if(address<outDataSegment->vmaddr||address>=outDataSegment->vmaddr+outDataSegment->vmsize)
					{
						continue;
					}
					
					int dataOffset=address-outDataSegment->vmaddr;
					unsigned int* pointer=(unsigned int*)((char*)outHeader+outDataSegment->fileoff+dataOffset);
					BOOL skip=[binds containsObject:@(dataOffset)];
					
					NSLog(@"rebase data offset %x address %x value %x%@",dataOffset,outDataSegment->vmaddr+dataOffset,*pointer,skip?@" (skipped)":@"");
								
					if(skip)
					{
						continue;
					}
					
					*outCursor=REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB|1;
					outCursor++;
					writeUleb((unsigned char**)&outCursor,dataOffset);
					
					*outCursor=REBASE_OPCODE_DO_REBASE_IMM_TIMES|1;
					outCursor++;
				}
				
				*outCursor=REBASE_OPCODE_DONE;
				outCursor++;
				
				outInfo->rebase_size=outCursor-(char*)outHeader-outInfo->rebase_off;
				
				outLinkeditSegment->filesize=(char*)outCursor-(char*)outHeader-outLinkeditSegment->fileoff;
				assert(outLinkeditSegment->filesize==outInfo->bind_size+outInfo->lazy_bind_size+outInfo->weak_bind_size+outInfo->export_size+outInfo->rebase_size);
				
				outLinkeditSegment->vmsize=outLinkeditSegment->filesize;
				
				break;
			}
			
			case LC_ID_DYLIB:
			case LC_LOAD_DYLIB:
			case LC_UUID:
				
				memcpy(outCommand,inCommand,inCommand->cmdsize);
				copied=true;
				break;
			
			default:
				NSLog(@"unhandled command %x",inCommand->cmd);
		}
		
		if(copied)
		{
			outHeader->ncmds++;
			outCommand=(struct load_command*)((char*)outCommand+outCommand->cmdsize);
		}
		
		inCommand=(struct load_command*)((char*)inCommand+inCommand->cmdsize);
	}
	outHeader->sizeofcmds=(char*)outCommand-(char*)(outHeader+1);
	
	outData.length=outLinkeditSegment->fileoff+outLinkeditSegment->filesize;
	
	return outData;
}

int main(int argCount,char** args)
{
	@autoreleasepool
	{
		assert(argCount>=3);
		NSString* cachePath=@(args[1]);
		
		NSLog(@"read %@",cachePath);
		NSData* cacheData=[NSData dataWithContentsOfFile:cachePath];
		assert(cacheData);
		struct dyld_cache_header* cacheHeader=(struct dyld_cache_header*)cacheData.bytes;
		
		for(int argIndex=2;argIndex<argCount;argIndex++)
		{
			NSString* imagePath=@(args[argIndex]);
			NSData* imageData=extract(cacheHeader,imagePath);
			
			NSLog(@"write %@",imagePath.lastPathComponent);
			[imageData writeToFile:imagePath.lastPathComponent atomically:true];
		}
	}
}
