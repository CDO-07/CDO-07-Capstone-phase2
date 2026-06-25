output "vpc_id"                { value = aws_vpc.main.id }
output "public_subnet_id"      { value = aws_subnet.public.id }
output "private_app_subnet_id" { value = aws_subnet.private_app.id }
output "private_data_subnet_id"{ value = aws_subnet.private_data.id }
output "alb_sg_id"             { value = aws_security_group.alb.id }
output "app_sg_id"             { value = aws_security_group.app.id }
output "lambda_sg_id"          { value = aws_security_group.lambda.id }
