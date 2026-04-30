import json
import sys

def mask_config(input_file):
    try:
        with open(input_file, 'r', encoding='utf-8') as f:
            data = json.load(f)
            
        if 'experimental' in data and 'clash_api' in data['experimental']:
            data['experimental']['clash_api']['secret'] = 'TODO_REPLACE_THIS'
                
        if 'outbounds' in data:
            for outbound in data['outbounds']:
                if outbound.get('type') == 'vless':
                    outbound['server'] = 'TODO_REPLACE_THIS'
                    outbound['uuid'] = 'TODO_REPLACE_THIS'
                    
                    if 'tls' in outbound:
                        outbound['tls']['server_name'] = 'TODO_REPLACE_THIS'
                        if 'reality' in outbound['tls']:
                            outbound['tls']['reality']['public_key'] = 'TODO_REPLACE_THIS'
                            outbound['tls']['reality']['short_id'] = 'TODO_REPLACE_THIS'

        if 'route' in data and 'rules' in data['route']:
            for rule in data['route']['rules']:
                if 'ip_cidr' in rule:
                    # In the provided example, the GCP ip_cidr was masked
                    rule['ip_cidr'] = ['TODO_REPLACE_THIS', 'TODO_REPLACE_THIS']

        print(json.dumps(data, indent=2))
        
    except Exception as e:
        print(f"Error processing JSON: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <input_file>", file=sys.stderr)
        sys.exit(1)
    mask_config(sys.argv[1])
